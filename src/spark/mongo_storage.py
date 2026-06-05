from datetime import datetime, timezone
from decimal import Decimal
import json
from math import isfinite
import tempfile

import numpy as np
from pyspark.sql import Row
from pymongo import MongoClient

from app_config import MongoConfig


class MongoStorage:
    def __init__(self, cfg: MongoConfig):
        self.cfg = cfg
        self.client = MongoClient(cfg.uri)
        self.db = self.client[cfg.database]

    def close(self):
        self.client.close()

    def replace_training_data(self, df, source_path: str, batch_size: int = 1000) -> int:
        self.db[self.cfg.training_collection].delete_many({})

        partitions = max(df.rdd.getNumPartitions(), 8)
        mongo_uri = self.cfg.uri
        database = self.cfg.database
        collection_name = self.cfg.training_collection

        def write_partition(rows):
            client = MongoClient(mongo_uri)
            collection = client[database][collection_name]
            batch = []

            try:
                for row in rows:
                    batch.append(MongoStorage.clean_value(row))

                    if len(batch) >= batch_size:
                        collection.insert_many(batch)
                        batch = []

                if batch:
                    collection.insert_many(batch)
            finally:
                client.close()

        df.repartition(partitions).foreachPartition(write_partition)
        inserted = self.db[self.cfg.training_collection].count_documents({})

        self.db["imports"].insert_one({
            "collection": self.cfg.training_collection,
            "source_path": source_path,
            "rows": inserted,
        })

        return inserted

    def load_training_data(self, spark, columns: list[str]):
        projection = {column: 1 for column in columns}
        projection["_id"] = 0

        cursor = self.db[self.cfg.training_collection].find({}, projection)
        rows = 0

        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".jsonl",
            delete=False,
        ) as f:
            jsonl_path = f.name

            for doc in cursor:
                f.write(json.dumps(self.clean_value(doc), ensure_ascii=False))
                f.write("\n")
                rows += 1

        if rows == 0:
            raise ValueError("В MongoDB нет данных для обучения")

        return spark.read.json(jsonl_path)

    def save_training_results(self, clusters_df, profiles_df, centers_df, metrics: dict, model_info: dict) -> None:
        run_id = self._now().isoformat()

        self._replace_with_dataframe(self.cfg.clusters_collection, clusters_df)
        self._replace_with_dataframe(self.cfg.profiles_collection, profiles_df)
        self._replace_with_dataframe(self.cfg.centers_collection, centers_df)

        self._replace_with_documents(self.cfg.metrics_collection, [{
            **self.clean_value(metrics),
            "run_id": run_id,
        }])
        self._replace_with_documents(self.cfg.model_info_collection, [{
            **self.clean_value(model_info),
            "run_id": run_id,
        }])

    def save_prediction_summary(
        self,
        predictions_df,
        model_path: str,
        input_path: str,
        output_path: str,
    ) -> dict:
        run_id = self._now().isoformat()

        cluster_rows = (
            predictions_df
            .groupBy("prediction")
            .count()
            .orderBy("prediction")
            .toLocalIterator()
        )
        clusters = [
            {
                "prediction": int(row["prediction"]),
                "count": int(row["count"]),
            }
            for row in cluster_rows
        ]
        total_rows = sum(row["count"] for row in clusters)

        summary = {
            "run_id": run_id,
            "created_at": run_id,
            "model_path": model_path,
            "input_path": input_path,
            "output_path": output_path,
            "rows": total_rows,
            "clusters": clusters,
        }

        self.db[self.cfg.prediction_summary_collection].insert_one(
            self.clean_value(summary)
        )

        return summary

    def _replace_with_dataframe(self, collection_name: str, df, batch_size: int = 1000) -> int:
        collection = self.db[collection_name]
        collection.delete_many({})

        batch = []
        inserted = 0
        for row in df.toLocalIterator():
            batch.append(self.clean_value(row))

            if len(batch) >= batch_size:
                collection.insert_many(batch)
                inserted += len(batch)
                batch = []

        if batch:
            collection.insert_many(batch)
            inserted += len(batch)

        return inserted

    def _replace_with_documents(self, collection_name: str, docs: list[dict]) -> None:
        collection = self.db[collection_name]
        collection.delete_many({})
        if docs:
            collection.insert_many(docs)

    @staticmethod
    def clean_value(value):
        if isinstance(value, Row):
            return {k: MongoStorage.clean_value(v) for k, v in value.asDict(recursive=True).items()}
        if isinstance(value, dict):
            return {k: MongoStorage.clean_value(v) for k, v in value.items()}
        if isinstance(value, list):
            return [MongoStorage.clean_value(v) for v in value]
        if isinstance(value, tuple):
            return [MongoStorage.clean_value(v) for v in value]
        if isinstance(value, Decimal):
            return float(value)
        if isinstance(value, datetime):
            return value.isoformat()
        if isinstance(value, np.integer):
            return int(value)
        if isinstance(value, np.floating):
            return float(value)
        if isinstance(value, np.bool_):
            return bool(value)
        if isinstance(value, float) and not isfinite(value):
            return None
        return value

    def _now(self):
        return datetime.now(timezone.utc)
