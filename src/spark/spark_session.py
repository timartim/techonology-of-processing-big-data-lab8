import os

from pyspark.sql import SparkSession
from app_config import SparkConfig


class SparkManager:
    def __init__(self, cfg: SparkConfig):
        self.cfg = cfg

    def create_session(self) -> SparkSession:
        builder = (
            SparkSession.builder
            .appName(self.cfg.app_name)
            .config("spark.driver.memory", self.cfg.driver_memory)
            .config("spark.sql.shuffle.partitions", self.cfg.shuffle_partitions)
        )

        if self.cfg.master:
            builder = builder.master(self.cfg.master)

        for key, value in self.cfg.conf.items():
            builder = builder.config(key, value)

        driver_host = os.getenv("SPARK_DRIVER_HOST")
        if driver_host:
            builder = builder.config("spark.driver.host", driver_host)

        driver_bind_address = os.getenv("SPARK_DRIVER_BIND_ADDRESS")
        if driver_bind_address:
            builder = builder.config("spark.driver.bindAddress", driver_bind_address)

        driver_pod_name = os.getenv("SPARK_DRIVER_POD_NAME")
        if driver_pod_name:
            builder = builder.config("spark.kubernetes.driver.pod.name", driver_pod_name)

        spark = builder.getOrCreate()
        spark.sparkContext.setLogLevel(self.cfg.log_level)
        return spark
