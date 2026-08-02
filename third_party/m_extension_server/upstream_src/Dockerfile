FROM eclipse-temurin:21-jdk-jammy AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install curl coreutils zip -y
ENV HOME=/usr/app
RUN mkdir -p $HOME
WORKDIR $HOME
ADD . $HOME
RUN chmod +x ./AndroidCompat/getAndroid.sh
RUN ./AndroidCompat/getAndroid.sh
RUN ./gradlew :server:shadowJar --no-daemon --stacktrace

FROM gcr.io/distroless/java21-debian12
ARG JAR_FILE=/usr/app/server/build/*.jar
COPY --from=build $JAR_FILE /app/runner.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/runner.jar", "8080"]
