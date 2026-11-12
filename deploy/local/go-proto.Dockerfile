# Local build of a Go service (Game, Exam) for deploy/docker-compose.local.yml.
#
# Same image as the service's own Dockerfile, but it also generates what a fresh checkout
# may not have yet: the gRPC code from proto/ (make proto) and the go.sum entries
# (go mod tidy). So it builds with nothing but Docker on the machine.
#
# The build context is the service folder (services/game-service or services/exam-service).
FROM golang:1.22-alpine AS build
RUN apk add --no-cache protoc make git
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.35.1 \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
WORKDIR /src
COPY . .
RUN if ! ls internal/broker/brokerpb/*.pb.go >/dev/null 2>&1; then make proto; fi \
 && go mod tidy \
 && CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/server ./cmd/server

FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=build /out/server /server
ARG PORT=3001
ENV PORT=${PORT} GRPC_PORT=50051
EXPOSE ${PORT} 50051
HEALTHCHECK --interval=10s --timeout=3s CMD wget -qO- "http://localhost:${PORT}/health" || exit 1
ENTRYPOINT ["/server"]
