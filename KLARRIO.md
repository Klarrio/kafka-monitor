# Kafka Monitor Docker build
To build and push a new version of this to the artifactory you need to:
- change the version in the `klarrio.version` file
- Build the container via ./gradlew jar
- Change your wd to docker/
- Push the newly built jar to the artifactory using 
    - `make push -e PREFIX=registry.cp.kpn-dsh.com/dsh/klarrio-kafka-monitor -e TAG=`cat ../klarrio.version``
