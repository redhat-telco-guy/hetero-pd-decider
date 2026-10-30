# Builds the llm-d EPP with hetero-pd-decider: clone at BASE_COMMIT, apply the patch,
# vet + test (build fails on any failure), then compile a static binary.
FROM docker.io/library/golang:1.27.2 AS build
# Keep the Go toolchain within the build pod's thread/process limits (avoids "fatal error: newosproc").
ENV GOMAXPROCS=4 GOFLAGS=-p=4 GOGC=100
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BASE_COMMIT
WORKDIR /src
RUN test -n "$BASE_COMMIT" && \
    git clone -q https://github.com/llm-d/llm-d-inference-scheduler.git . && \
    git checkout -q "$BASE_COMMIT"
COPY hetero-pd-decider.patch /tmp/hetero-pd-decider.patch
RUN git apply /tmp/hetero-pd-decider.patch && git status --short
RUN go mod download

# Vet the touched packages and the EPP entrypoint (catches interface mismatches in the adapter).
RUN go vet ./pkg/epp/framework/plugins/scheduling/profilehandler/disagg/... ./cmd/epp/...

# New tests + existing deciders (regression check).
RUN go test -count=1 -cover \
      -run 'HeteroPD|TestDecide|TestConfigValidate|Disagg|PrefixBased' \
      ./pkg/epp/framework/plugins/scheduling/profilehandler/disagg/... -v \
    | grep -E '^(--- (PASS|FAIL)|PASS|FAIL|ok|coverage|panic)|_test.go:[0-9]+'

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -ldflags="-s -w -X github.com/llm-d/llm-d-router/version.CommitSHA=${BASE_COMMIT}+hetero-pd -X github.com/llm-d/llm-d-router/version.BuildRef=hetero-pd-dev" \
      -o /out/epp cmd/epp/main.go

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/epp /app/epp
USER 65532:65532
EXPOSE 9002 9003 9090 5557
ENTRYPOINT ["/app/epp"]
