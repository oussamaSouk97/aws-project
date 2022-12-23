 #!/bin/bash -i

set -e

# import cli cmd functions
source utils/cli_helper.sh

######
## Function that setup an EC2 instance with mysql 
# GLOBALS: 
# 	SUBNETS_1 : The used subnet Id
#   INSTANCE_ID : The generated instance Id  
#   INSTANCE_DNS : The generated EC2 Dns  
# OUTPUTS: 
# 	The instance DNS with all needed setup
######
function setup {
    if [[ -f "backup.txt" ]]; then
        rm -f keypair.pem backup.txt
    fi

    #Setup network security
    create_security_group
    create_keypair

    #Setup EC2 instances
    SUBNETS_1=$(aws ec2 describe-subnets --query "Subnets[0].SubnetId" --output text)

    echo "Launch standalone instance"
    STANDALONE_ID=$(launch_ec2_instance $SUBNETS_1 "t2.micro" "config/standalone/setup.txt")  
    echo "STANDALONE_ID=\"$STANDALONE_ID\"" >>backup.txt

    echo "Launch master instance"
    MASTER_ID=$(launch_ec2_instance $SUBNETS_1 "t2.micro" "config/cluster/master.txt") 
    echo "MASTER_ID=\"$MASTER_ID\"" >>backup.txt  

    echo "Waiting for standalone  and master  instances to complete initialization...."
    aws ec2 wait instance-status-ok --instance-ids ${STANDALONE_ID} ${MASTER_ID} 

    echo "Launch slaves instance"
    SALVE1_ID=$(launch_ec2_instance $SUBNETS_1 "t2.micro" "config/cluster/slave1.txt")
    SALVE2_ID=$(launch_ec2_instance $SUBNETS_1 "t2.micro" "config/cluster/slave2.txt")
    SALVE3_ID=$(launch_ec2_instance $SUBNETS_1 "t2.micro" "config/cluster/slave3.txt")
    
    #Save the returned InstanceId as backup 
    echo "SALVE1_ID=\"$SALVE1_ID\"" >>backup.txt 
    echo "SALVE2_ID=\"$SALVE2_ID\"" >>backup.txt
    echo "SALVE3_ID=\"$SALVE3_ID\"" >>backup.txt

    echo "Waiting for slaves instances to complete initialization...."
    aws ec2 wait instance-status-ok --instance-ids ${SALVE1_ID} ${SALVE2_ID} ${SALVE3_ID}
    
    #Wait to complete manual setup
    while true; do
        read -p "Waiting for manuel setup to be completed, press y to continue" yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) exit;;
                * ) echo "Please answer yes or no.";;
        esac
    done

    echo "Launch proxy instance"
    PROXY_ID=$(launch_ec2_instance $SUBNETS_1 "t2.large" "config/proxy.txt") 
    #Save the returned InstanceId as backup 
    echo "PROXY_ID=\"$PROXY_ID\"" >>backup.txt  

    echo "Waiting for proxy instance to complete initialization...."
    aws ec2 wait instance-status-ok --instance-ids ${PROXY_ID}
    
    #Retrieve the proxy DNS
    PROXY_DNS=$(get_ec2_public_dns $PROXY_ID)
    echo "PROXY_DNS=\"$PROXY_DNS\"" >>backup.txt

    #Upload needed script in proxy instance
    scp -i keypair.pem proxy/proxy_pattern.py ubuntu@$PROXY_DNS:/home/ubuntu

    #Retrieve needed ip
    MASTER_DNS=$(get_ec2_public_dns $MASTER_ID)
    SLAVE1_DNS=$(get_ec2_public_dns $SALVE1_ID)
    SLAVE2_DNS=$(get_ec2_public_dns $SALVE2_ID)
    SLAVE3_DNS=$(get_ec2_public_dns $SALVE3_ID)
    
    #Deploy the proxy on the instance using cluster private IPs
    ssh -i keypair.pem ubuntu@$PROXY_DNS "bash -s \"$MASTER_DNS\" \"$SLAVE1_DNS\" \"$SLAVE2_DNS\" \"$SLAVE3_DNS\"" < proxy/deploy.sh 
 
    echo "Setup Completed"

}

######
## Function that run sysbench tool on mysql standalone and cluster
# OUTPUTS: 
# 	The sysbench metrics
######
function sysbench {
    #Retrieve needed dns
    STANDALONE_DNS=$(get_ec2_public_dns $STANDALONE_ID)

    echo "Start sysbench on standalone instance"
    ssh -i keypair.pem ubuntu@$STANDALONE_DNS 'bash -s' < sysbench/script.sh 2>> sysbench/standalone_result.txt

    echo "Start sysbench on cluster" 
    ssh -i keypair.pem ubuntu@$MASTER_DNS 'bash -s' < sysbench/script.sh 2>> sysbench/cluster_result.txt
}

######
## Function that run the client to reach proxy
# OUTPUTS: 
# 	Mysql queries results
######
function client {
    python3 proxy/client_proxy $PROXY_DNS direct write
    python3 proxy/client_proxy $PROXY_DNS direct read
    python3 proxy/client_proxy $PROXY_DNS random read
    python3 proxy/client_proxy $PROXY_DNS custom read
}

######
## Function that wipe all the setup on AWS
# OUTPUTS: 
# 	Terminate the instance 
#   Delete the keypair
#   Delete the security group 
######
function wipe {

    source backup.txt

    ## Terminate the ec2 instances
    if [[ -n "${STANDALONE_ID}" ]]; then
        echo "Terminate the ec2 instance..."
        aws ec2 terminate-instances --instance-ids $STANDALONE_ID $MASTER_ID  $SLAVE1_ID $SLAVE2_ID $SLAVE3_ID $PROXY_ID
        ## Wait for instances to enter 'terminated' state
        echo "Wait for instances to enter terminated state..."
        aws ec2 wait instance-terminated --instance-ids $STANDALONE_ID $MASTER_ID  $SLAVE1_ID $SLAVE2_ID $SLAVE3_ID $PROXY_ID
        echo "instance terminated"
    fi

    # Delete Key pair
    if [[ -f "backup.txt" ]]; then
        ## Delete key pair
        echo "Delete key pair..."
        aws ec2 delete-key-pair --key-name keypair
        rm -f keypair.pem
        echo "key pair Deleted"
    fi    

    ## Delete custom security group
    if [[ -n "$SECURITY_GROUP_ID" ]]; then
        echo "Delete custom security group..."
        delete_security_group $SECURITY_GROUP_ID
        echo "Security-group deleted"
    fi
}

# Main
setup
sysbench
client
wipe