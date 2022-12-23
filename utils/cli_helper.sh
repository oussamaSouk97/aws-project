#!/bin/bash


######
## Function that create a security group and add ingress rules
# GLOBALS: 
# 	SECURITY_GROUP_ID : The generated security group id 
# OUTPUTS: 
# 	The generated security group Id
######
function create_security_group {
    echo "Create security group..."
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name mysql-security-group \
        --description 'Mysql security group' \
        --query 'GroupId' \
        --output text)

    #Save the returned SECURITY_GROUP_ID as backups    
    echo "SECURITY_GROUP_ID=\"$SECURITY_GROUP_ID\"" >>backup.txt    
    add_security_ingress_rules '[{"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "tcp", "FromPort": 3306, "ToPort": 3306, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "icmp", "FromPort": -1, "ToPort": -1, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "tcp", "FromPort": 5001, "ToPort": 5001, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]'
    echo "Done"
}

######
## Function that add ingress rules to an existing security group
# GLOBALS: 
# 	SECURITY_GROUP_ID : The generated security group id 
# ARGUMENTS: 
# 	rules permissions to add
# OUTPUTS: 
# 	Add ingress rules on port 22(ssh), 3306(mysql) and 5001 proxy
######
function add_security_ingress_rules {
    echo "Add ingress rules"
    local rules_permissions=$1
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --ip-permissions "${rules_permissions}"
}

######
## Function that create a keypair and import the key localy
# OUTPUTS: 
# 	Create a key on aws and save the generated key on a local file
######
function create_keypair {
    echo "Create a key-pair... "
    aws ec2 create-key-pair --key-name keypair --query 'KeyMaterial' --output text >keypair.pem
    ## Change access to key pair to make it secure
    chmod 400 keypair.pem
    echo "Done"
}

######
## Function that lanch an ubuntu instance(m4.large)
# GLOBALS: 
# 	SECURITY_GROUP_ID : The generated security group id 
# ARGUMENTS: 
# 	Subnet Id
#   Instance type = m4.large 
# OUTPUTS: 
# 	Create a new instance
######
function launch_ec2_instance {
    local subnet=$1
    local instance_type=$2
    local config_file=$3
    aws ec2 run-instances \
        --image-id ami-09e67e426f25ce0d7 \
        --instance-type $instance_type \
        --count 1 \
        --subnet-id $subnet --key-name keypair \
        --monitoring "Enabled=true" \
        --security-group-ids $SECURITY_GROUP_ID \
        --user-data file://$config_file \
        --query 'Instances[*].InstanceId[]' \
        --output text
}


######
## Function that get the public dns of an instance
# ARGUMENTS: 
# 	Created instance id
# OUTPUTS: 
# 	 the public dns value
######
function get_ec2_public_dns {
    local instance_id=$1
    aws ec2 describe-instances \
    --instance-ids $instance_id \
    --query 'Reservations[].Instances[].PublicDnsName' \
    --output text
}

######
## Function that delete a security group
# ARGUMENTS: 
# 	security group id
# OUTPUTS: 
# 	delete the security id 
######
function delete_security_group {
    local security_group_id=$1
    aws ec2 delete-security-group --group-id $security_group_id
}

