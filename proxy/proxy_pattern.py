#!/usr/bin/python3

import socket
import pickle
import random
import argparse
import mysql.connector
from pythonping import ping


parser = argparse.ArgumentParser()
parser.add_argument("master_dns", help="The master dns")
parser.add_argument("--list", nargs="+", help="The list of slaves dns")

# Retrieve args
args = parser.parse_args()
master_dns = args.master_dns
slaves_dns_list = args.list

##########################
### Main function
##########################
def main():
    listen = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listen.bind(("", 5001))
    # Keep till 10 cnx in the queue
    listen.listen(10)
    while True:

        # Start listening to client calls
        conn, addr = listen.accept()
        data = conn.recv(2048)
        if not data:
            break
        cmd_type, implementation, command = load_data(data)
        # handle write queries that will automatically redirected to master node
        if cmd_type == "write" and implementation == "direct":
            target_name = "master"
            cnx = db_cnx(master_dns)
            write(conn, cnx, command, target_name)
        # handle read queries and send them to master node
        if cmd_type == "read" and implementation == "direct":
            target_server = "master"
            cnx = db_cnx(master_dns)
            read(conn, cnx, command, target_server)
        # handle read queries and send them to random salves
        if cmd_type == "read" and implementation == "random":
            random_slave_ip = random.choice(slaves_dns_list)
            target_server = "slave " + str(random_slave_ip)
            cnx = db_cnx(random_slave_ip)
            read(conn, cnx, command, target_server)
        # handle read queries and send them to the best ping time node
        if cmd_type == "read" and implementation == "custom":
            best_cnx = custom()
            if best_cnx == master_dns:
                target_server = "master"
            else:
                target_server = "slave"
            cnx = db_cnx(best_cnx)
            read(conn, cnx, command, target_server)


################################
### Open cnx with mysql
# return mysql connector
################################
def db_cnx(target_ip):
    cnx = mysql.connector.connect(
        user="proxy",
        host=target_ip,
        database="sakila",
    )
    print("Connection to DB opened")
    return cnx


#######################################
### Write into database
## conn  : socket connector
## db_cnx : mysql connector
## command  : sql command (ex insert)
## target_node : master node
# return: Query repsone to client
#######################################
def write(conn, db_cnx, command, target_node):
    cursor = db_cnx.cursor()
    cursor.execute(command)
    db_cnx.commit()
    response = {"handled by": target_node, "response": "OK"}
    response = pickle.dumps(response)
    conn.send(response)


#######################################
### Read from database
## conn  : socket connector
## db_cnx : mysql connector
## command  : sql command (ex select)
## target_node : master/slave
#  return: Query repsone to client
#######################################
def read(conn, db_cnx, command, target_node):
    cursor = db_cnx.cursor()
    cursor.execute(command)
    print(f"handled by :{target_node}")
    result = cursor.fetchall()
    response = {"handled by": {target_node}, "result": result}
    response = pickle.dumps(response)
    conn.send(response)


#######################################
### Parse data sent by the client
## data  : json data sent by the client
# return: Needed data to treat
#######################################
def load_data(data):
    data = pickle.loads(data)
    return data["type"], data["implementation"], data["command"]


#############################################
### Handle custom logic to choice best cnx
# return: best node ping time
#############################################
def custom():
    responses = {}
    # Ping master node
    master_cnx = db_cnx(master_dns)
    responses[master_cnx.server_host] = ping(master_cnx.server_host).rtt_avg

    # Ping slaves nodes
    slaves_cnx = [db_cnx(ip) for ip in slaves_dns_list]
    for slave in slaves_cnx:
        response = ping(slave.server_host)
        responses[slave.server_host] = response.rtt_avg

    # Get ping time min
    best_node = min(responses, key=responses.get)

    return str(best_node)


if __name__ == "__main__":
    main()
