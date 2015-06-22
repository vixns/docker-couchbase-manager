#!/bin/bash 

resp='HTTP/1.1 500 OK\r\n\r\nnok\n'; 

check_couchbase () {
    local nodes=$(curl -s -X GET http://${CONSUL_HOST}:8500/v1/catalog/service/couchbase | \
        jq -r '(.[] | .ServiceAddress + ":" + ( .ServicePort | tostring))' 2> /dev/null)
local leader
if [ -n "$nodes" ]
    then
    for s in $nodes
    do
        if [ -n "$(curl -s -XGET http://$s/pools | jq -r '.pools[]')" ]
            then
            leader=$s
            break
        fi
    done

    if [ -z "$leader" ]
        then
        leader=$(echo $nodes | cut -d' ' -f 1)
        if [ -z "$leader" ]
            then
            sleep 10
            exit 1
        fi
        curl -s -XPOST http://$leader/nodes/self/controller/settings \
        -d path="/opt/couchbase/var/lib/couchbase/data" \
        -d index_path="/opt/couchbase/var/lib/couchbase/data" \
        -d hostname="$(echo $leader | cut -d':' -f 1)"

        curl -s -XPOST http://$leader/settings/web \
        -d port="SAME" -d username="${CB_USERNAME-admin}" -d password="${CB_PASSWORD-password}"

        curl -s -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} -XPOST http://$leader/pools/default -d memoryQuota="${CB_MEMORY-256}"
        curl -s -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} -XPOST http://$leader/pools/default/buckets \
        -d flushEnabled="1" \
        -d replicaIndex="1" \
        -d replicaNumber="2" \
        -d name="default" \
        -d bucketType="membase" \
        -d ramQuotaMB="${CB_MEMORY-256}" \
        -d evictionPolicy="valueOnly" \
        -d authType="sasl" \
        -d saslPassword="" \
        -d threadsNumber="8"
        curl -s -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} -XPOST http://$leader/settings/autoFailover -d enabled="true" -d timeout="120"
    fi

    for s in $nodes
    do
        if [ -z "$(curl -s -XGET http://$s/pools | jq -r '.pools[]')" ]
            then
            hostname=$(echo $s | cut -d':' -f 1)
            curl -s -XPOST http://$s/nodes/self/controller/settings \
            -d path="/opt/couchbase/var/lib/couchbase/data" \
            -d index_path="/opt/couchbase/var/lib/couchbase/data" \
            -d hostname="${hostname}"
            [ $? -eq 0 ] || return
            curl -s -XPOST http://$s/settings/web \
            -d port="SAME" -d username="${CB_USERNAME-admin}" -d password="${CB_PASSWORD-password}"
            curl -s -XPOST -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} \
            http://$leader/controller/addNode \
            -d "hostname=$hostname&user=${CB_USERNAME-admin}&password=${CB_PASSWORD-password}"
        fi
    done

    failedNodes="$(curl -s -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader/pools/default | jq -r '.nodes | map(select(.status | contains("unhealthy"))) | map(.otpNode) | join(" ")')"

    if [ -n "$failedNodes" ]
        then
        for n in $failedNodes
        do
            curl -s -XPOST -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} \
            http://$leader/controller/failOver -d otpNode=$n
        done
    fi

    addedNodes="$(curl -s -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader/pools/default | jq -r '.nodes | map(select(.clusterMembership | contains("inactiveAdded"))) | map(.otpNode) | join(",")')"             
    ejectedNodes="$(curl -s -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader/pools/default | jq -r '.nodes | map(select(.clusterMembership | contains("inactiveFailed"))) | map(.otpNode) | join(",")')"          

    if [ -n "$addedNodes" ] || [ -n "$ejectedNodes" ]
        then
        knownNodes="$(curl -s -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader/pools/default | jq -r '.nodes | map(select(.clusterMembership | [contains("inactiveAdded") , contains("active")] | any)) | map(.otpNode) | join(",")')"   

        curl -s -XPOST -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader/controller/rebalance -d "knownNodes=$knownNodes&ejectedNodes=$ejectedNodes"
    fi

    resp='HTTP/1.1 200 OK\r\n\r\nok\n'; 
fi
}


while true
do 
    set +e
    check_couchbase 
    set -e
    echo -e $resp | nc -q 1  -n -l -p ${HTTP_PORT-8080} | ( cat > /dev/null )
done