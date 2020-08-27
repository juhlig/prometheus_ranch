PROJECT = prometheus_ranch
PROJECT_DESCRIPTION = Prometheus collector for Ranch
PROJECT_VERSION = 0.2.0
DEPS = protobuffs prometheus

dep_prometheus = git https://github.com/deadtrickster/prometheus.erl.git v4.6.0

include erlang.mk
