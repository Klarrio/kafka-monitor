# Kafka Monitor Docker build
To build and push a new version of this to the artifactory you need to:
- Build the container via ./gradlew jar
- Change your wd to docker/
- Push the newly built jar to the artifactory using 
    - `make push -e PREFIX=klarrio-docker.jfrog.io/opensource/kafka-monitor -e TAG=<version>`