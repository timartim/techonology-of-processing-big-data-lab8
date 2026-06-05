from dataclasses import dataclass, field
from pathlib import Path
import json
import os


@dataclass
class SparkConfig:
    app_name: str
    master: str
    driver_memory: str
    shuffle_partitions: str
    log_level: str
    conf: dict[str, str] = field(default_factory=dict)


@dataclass
class DataConfig:
    input_path: str
    clusters_csv_path: str
    profiles_csv_path: str
    centers_csv_path: str
    metrics_json_path: str
    predictions_csv_path: str
    model_root: str


@dataclass
class MongoConfig:
    uri: str
    database: str
    training_collection: str
    clusters_collection: str
    profiles_collection: str
    centers_collection: str
    metrics_collection: str
    model_info_collection: str
    prediction_summary_collection: str


@dataclass
class PreprocessingConfig:
    min_non_null_ratio: float
    target_n: int
    imputer_strategy: str


@dataclass
class TrainingConfig:
    k_min: int
    k_max: int
    seed: int
    metric_name: str
    distance_measure: str


@dataclass
class AppConfig:
    spark: SparkConfig
    data: DataConfig
    mongo: MongoConfig
    preprocessing: PreprocessingConfig
    training: TrainingConfig
    base_dir: Path


def load_config(config_path: str | None = None) -> AppConfig:
    path = Path(config_path) if config_path else Path(__file__).resolve().parent / "config.json"

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    mongo_data = data["mongo"]
    mongo_data["uri"] = os.getenv("MONGO_URI", mongo_data["uri"])
    mongo_data["database"] = os.getenv("MONGO_DATABASE", mongo_data["database"])

    return AppConfig(
        spark=SparkConfig(**data["spark"]),
        data=DataConfig(**data["data"]),
        mongo=MongoConfig(**mongo_data),
        preprocessing=PreprocessingConfig(**data["preprocessing"]),
        training=TrainingConfig(**data["training"]),
        base_dir=path.parent.resolve(),
    )
