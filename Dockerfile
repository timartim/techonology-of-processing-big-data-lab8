FROM apache/spark:4.1.1-python3

USER root

WORKDIR /opt/app

COPY requirements.txt /opt/app/requirements.txt
RUN pip install --no-cache-dir -r /opt/app/requirements.txt

COPY src /opt/app/src

RUN mkdir -p /opt/app/shared/data /opt/app/shared/artifacts \
    && chown -R 185:0 /opt/app /opt/app/shared

USER 185

WORKDIR /opt/app/src/spark

ENV PYTHONPATH=/opt/app/src/spark

EXPOSE 8000

CMD ["uvicorn", "api:app", "--host", "0.0.0.0", "--port", "8000"]
