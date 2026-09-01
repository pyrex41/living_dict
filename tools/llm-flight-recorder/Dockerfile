FROM python:3.12-alpine
COPY tools/llm_flight_recorder.py /usr/local/bin/llm-flight-recorder
RUN chmod 0555 /usr/local/bin/llm-flight-recorder
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/llm-flight-recorder"]
