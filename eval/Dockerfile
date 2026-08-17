FROM python:3.12-slim

WORKDIR /suite
COPY . /suite
RUN python -m pip install --no-cache-dir -e .

ENTRYPOINT ["ldeval"]
CMD ["list"]

