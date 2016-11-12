#!/bin/sh

CURL="curl --connect-timeout 1 -s"
while true
do
    IPS="$(/dig-srv.sh $CB_HOSTNAME)"
    leader=""

# test if leader exists
for IP in $IPS
do
    if [ -n "$($CURL -XGET http://$IP:8091/pools | jq -r '.pools[]')" ]
        then
        leader=$IP
        break
    fi  
done

# no leader yet
if [ -z "$leader" ]
    then
    leader=$(echo $IPS | head -1)
    if [ -z "$leader" ]
        then
        #still no leader, wait and loop
        sleep 10
        continue
    fi
    # leader config

    $CURL \
    -XPOST http://$leader:8091/node/controller/setupServices \
    -d 'services=kv%2Cindex%2Cn1ql'

    $CURL -XPOST http://$leader:8091/nodes/self/controller/settings \
    -d path="/opt/couchbase/var/lib/couchbase/data" \
    -d index_path="/opt/couchbase/var/lib/couchbase/data" \
    -d hostname="$leader"

    $CURL -XPOST http://$leader:8091/settings/web \
    -d port="SAME" -d username="${CB_USERNAME-admin}" -d password="${CB_PASSWORD-password}"

    $CURL -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} \
    -XPOST http://$leader:8091/settings/autoFailover -d enabled="true" -d timeout="120"

    $CURL -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} \
    -XPOST http://$leader:8091/pools/default \
    -d memoryQuota="${CB_MEMORY-256}" \
    -d indexMemoryQuota="${CB_MEMORY-256}"

    if [ -z "$CB_AS_MEMCACHED" ]
        then
        $CURL -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} -XPOST http://$leader:8091/pools/default/buckets \
        -d flushEnabled="1" \
        -d replicaIndex="1" \
        -d replicaNumber="2" \
        -d name="default" \
        -d bucketType="couchbase" \
        -d ramQuotaMB="${CB_MEMORY-256}" \
        -d evictionPolicy="valueOnly" \
        -d authType="sasl" \
        -d threadsNumber="8"
    else
        $CURL -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} -XPOST http://$leader:8091/pools/default/buckets \
        -d flushEnabled="1" \
        -d name="default" \
        -d bucketType="memcached" \
        -d ramQuotaMB="${CB_MEMORY-256}" \
        -d authType="sasl" \
        -d threadsNumber="8"
    fi

fi

addedNodes="$($CURL -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader:8091/pools/default | jq -r '.nodes | map(select(.clusterMembership)) | map(.otpNode) | join(",")')"

for IP in $IPS
do
    [ "$IP" = "$leader" ] && continue
    echo "$addedNodes" | grep -q -v "$IP" 
    [ $? -eq 0 ] || continue
    if [ -z "$($CURL -XGET http://$IP:8091/pools | jq -r '.pools[]')" ]
        then

        $CURL -XPOST http://$IP:8091/nodes/self/controller/settings \
        -d path="/opt/couchbase/var/lib/couchbase/data" \
        -d index_path="/opt/couchbase/var/lib/couchbase/data" \
        -d hostname="${IP}"
        [ $? -eq 0 ] || continue

        $CURL -XPOST -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} \
        http://$leader:8091/controller/addNode \
        -d "hostname=$IP&user=${CB_USERNAME-admin}&password=${CB_PASSWORD-password}&services=kv%2Cindex%2Cn1ql"
    fi
done

failedNodes="$($CURL -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader:8091/pools/default | jq -r '.nodes | map(select(.status | contains("unhealthy"))) | map(.otpNode) | join(" ")')"

if [ -n "$failedNodes" ]
    then
    for n in $failedNodes
    do
        $CURL -XPOST -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} \
        http://$leader:8091/controller/failOver -d otpNode=$n
    done
fi

addedNodes="$($CURL -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader:8091/pools/default | jq -r '.nodes | map(select(.clusterMembership | contains("inactiveAdded"))) | map(.otpNode) | join(",")')"             
ejectedNodes="$($CURL -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader:8091/pools/default | jq -r '.nodes | map(select(.clusterMembership | contains("inactiveFailed"))) | map(.otpNode) | join(",")')"          

if [ -n "$addedNodes" ] || [ -n "$ejectedNodes" ]
    then
    knownNodes="$($CURL -XGET -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader:8091/pools/default | jq -r '.nodes | map(select(.clusterMembership | [contains("inactiveAdded") , contains("active")] | any)) | map(.otpNode) | join(",")')"   

    curl -s -XPOST -u ${CB_USERNAME-admin}:${CB_PASSWORD-password} http://$leader:8091/controller/rebalance -d "knownNodes=$knownNodes&ejectedNodes=$ejectedNodes"
fi


sleep 10
done
