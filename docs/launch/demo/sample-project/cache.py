# We chose Redis over Memcached for the session cache because we need
# pub/sub for live presence, which Memcached can't do.
TTL_SECONDS = 3600
