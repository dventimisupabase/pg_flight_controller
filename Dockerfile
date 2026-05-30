# Test image: PostgreSQL + pgTAP (for pg_prove-driven tests).
# PG_VERSION is supplied by docker-compose (defaults to 17).
ARG PG_VERSION=17
FROM postgres:${PG_VERSION}
ARG PG_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "postgresql-${PG_VERSION}-pgtap" \
      libtap-parser-sourcehandler-pgtap-perl \
 && rm -rf /var/lib/apt/lists/*
# postgresql-NN-pgtap ships the extension SQL; pg_prove (+ DBD::Pg) comes from
# libtap-parser-sourcehandler-pgtap-perl.
