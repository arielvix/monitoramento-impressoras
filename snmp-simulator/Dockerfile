FROM python:3.12-slim
RUN pip install --no-cache-dir snmpsim==1.2.2 pysmi==1.6.2 && useradd --create-home simulator
USER simulator
ENTRYPOINT ["snmpsim-command-responder", "--data-dir=/data", "--agent-udpv4-endpoint=0.0.0.0:1161", "--cache-dir=/tmp/snmpsim", "--log-level=error"]
