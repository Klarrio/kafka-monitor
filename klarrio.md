# Kafka Monitor Docker build
All build metadata is stored in [klarrio-build.sh](klarrio-build.sh).

To create a Docker snapshot build and push to the remote registry:
```
./klarrio-build.sh snapshot
```

To release the project:
```
./klarrio-build.sh -t major|minor|revision release
```
