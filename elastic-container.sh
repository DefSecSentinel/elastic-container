#!/bin/bash

# Simple script to start an Elasticsearch and Kibana instance with Fleet and the Detection Engine. No data is retained. For information on customizing, see the Github repository.
#
# Usage:
# ./elastic-container.sh [OPTION]
#
# Options:
# stage - download the Elasticsearch, Kibana, and Elastic-Agent Docker images. This does not start them.
# start - start the Elasticsearch node, connected Kibana instance, and start the Elastic-Agent as a Fleet Server.
# stop - stop the Elasticsearch node, connected Kibana instance, and Fleet Server.
# restart - restart the Elasticsearch, connected Kibana instance, and Fleet Server.
# status - get the status of the Elasticsearch node, connected Kibana instance, and Fleet Server.
#
# More information at https://github.com/peasead/elastic-container"

# Define variables
ELASTIC_USERNAME="elastic"
ELASTIC_PASSWORD="password"
ELASTICSEARCH_URL="http://elasticsearch:9200"
LOCAL_ES_URL="http://127.0.0.1:9200"
KIBANA_URL="http://kibana:5601"
LOCAL_KBN_URL="http://127.0.0.1:5601"
FLEET_URL="http://fleet-server:8220"
STACK_VERSION="7.17.0"
HEADERS=(
  -H "kbn-version: ${STACK_VERSION}"
  -H "kbn-xsrf: kibana"
  -H 'Content-Type: application/json'
)

# Create the script usage menu
usage() {
  cat <<EOF | sed -e 's/^  //'
  usage: ./elastic-container.sh [-v] (stage|start|stop|restart|status|help)

  actions:
    stage     downloads all necessary images to local storage
    start     creates network and configures containers to run
    stop      stops the containers created and removes the network
    restart   simply restarts all the stack containers
    status    check the status of the stack containers
    help      print this message

  flags:
    -v        enable verbose output
EOF
}

# Create a function to enable the Detection Engine and load prebuilt rules in Kibana
configure_kbn() {
  MAXTRIES=15
  i=${MAXTRIES}

  while [ $i -gt 0 ]; do
    STATUS=$(curl -I "${LOCAL_KBN_URL}" 2>&3 | head -n 1 | cut -d$' ' -f2)

    echo
    echo "Attempting to enable the Detection Engine and Prebuilt-Detection Rules"

    if [ "${STATUS}" == "302" ]; then
      echo
      echo "Kibana is up. Proceeding"
      echo
      output=$(curl --silent "${HEADERS[@]}" --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPOST "${LOCAL_KBN_URL}/api/detection_engine/index" 2>&3)
      [[ $output =~ '"acknowledged":true' ]] || (
        echo
        echo "Detection Engine setup failed :-("
        exit 1
      )

      echo "Detection engine enabled. Installing prepackaged rules."
      curl --silent "${HEADERS[@]}" --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPUT "${LOCAL_KBN_URL}/api/detection_engine/rules/prepackaged" 1>&3 2>&3

      echo
      echo "Prebuilt Detections Enabled!"
      break
    else
      echo
      echo "Kibana still loading. Trying again in 40 seconds"
    fi

    sleep 40
    i=$((i - 1))
  done

  [ $i -eq 0 ] && echo "Exceeded MAXTRIES (${MAXTRIES}) to setup detection engine." && exit 1
}

# Logic to enable the verbose output if needed
OPTIND=1 # Reset in case getopts has been used previously in the shell.

verbose=0

while getopts "v" opt; do
  case "$opt" in
  v)
    verbose=1
    ;;
  *) ;;
  esac
done

shift $((OPTIND - 1))

[ "${1:-}" = "--" ] && shift

ACTION="${*:-help}"

if [ $verbose -eq 1 ]; then
  exec 3<>/dev/stderr
else
  exec 3<>/dev/null
fi

case "${ACTION}" in

"stage")
  # Collect the Elastic, Kibana, and Elastic-Agent Docker images
  docker pull docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
  docker pull docker.elastic.co/kibana/kibana:${STACK_VERSION}
  docker pull docker.elastic.co/beats/elastic-agent:${STACK_VERSION}
  ;;

"start")
  echo "Starting Elastic Stack network and containers"

  # Create the Docker network
  docker network create elastic 1>&3 2>&3

  # Start the Elasticsearch container
  docker run -d --network elastic --rm --name elasticsearch -p 9200:9200 -p 9300:9300 \
    -e "discovery.type=single-node" \
    -e "xpack.security.enabled=true" \
    -e "xpack.security.authc.api_key.enabled=true" \
    -e "ELASTIC_PASSWORD=${ELASTIC_PASSWORD}" \
    docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION} 1>&3 2>&3

  # Start the Kibana container
  docker run -d --network elastic --rm --name kibana -p 5601:5601 \
    -v "$(pwd)/kibana.yml:/usr/share/kibana/config/kibana.yml" \
    -e "ELASTICSEARCH_HOSTS=${ELASTICSEARCH_URL}" \
    -e "ELASTICSEARCH_USERNAME=elastic" \
    -e "ELASTICSEARCH_PASSWORD=${ELASTIC_PASSWORD}" \
    docker.elastic.co/kibana/kibana:${STACK_VERSION} 1>&3 2>&3

  # Start the Elastic Fleet Server container
  docker run -d --network elastic --rm --name fleet-server -p 8220:8220 \
    -e "KIBANA_HOST=${KIBANA_URL}" \
    -e "KIBANA_USERNAME=elastic" \
    -e "KIBANA_PASSWORD=${ELASTIC_PASSWORD}" \
    -e "ELASTICSEARCH_HOSTS=${ELASTICSEARCH_URL}" \
    -e "ELASTICSEARCH_USERNAME=elastic" \
    -e "ELASTICSEARCH_PASSWORD=${ELASTIC_PASSWORD}" \
    -e "KIBANA_FLEET_SETUP=1" \
    -e "FLEET_ENROLL=1" \
    -e "FLEET_SERVER_INSECURE_HTTP=1" \
    -e "FLEET_SERVER_ENABLE=true" \
    -e "FLEET_SERVER_ELASTICSEARCH_HOST=${ELASTICSEARCH_URL}" \
    -e "FLEET_URL=${FLEET_URL}" \
    docker.elastic.co/beats/elastic-agent:${STACK_VERSION} 1>&3 2>&3

# Enables the Detection Engine and Prebuilt Rules function created above
  configure_kbn

  echo
  echo "Browse to http://localhost:5601"
  echo "Username: elastic"
  echo "Passphrase: ${ELASTIC_PASSWORD}"
  echo
  ;;

"stop")
  echo "#####"
  echo "Stopping and removing all Elastic Stack components."
  echo "#####"
  docker stop fleet-server 2>&3
  docker stop kibana 2>&3
  docker stop elasticsearch 2>&3
  docker network rm elastic 2>&3
  ;;

"restart")
  echo "#####"
  echo "Restarting all Elastic Stack components."
  echo "#####"
  docker restart elasticsearch 2>&3
  docker restart kibana 2>&3
  docker restart fleet-server 2>&3
  ;;

"status")
  docker ps -f "name=kibana" -f "name=elasticsearch" -f "name=fleet-server" --format "table {{.Names}}: {{.Status}}"
  ;;

"help")
  usage
  ;;

*)
  echo -e "Proper syntax not used. See the usage\n"
  usage
  ;;
esac

# Close FD 3
exec 3>&-
