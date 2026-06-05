import os
from pathlib import Path

from fastapi import FastAPI
from pydantic import BaseModel

from app_config import load_config
from service import FoodClusterService


DEFAULT_CONFIG = Path(__file__).resolve().parent / "config.k8s-service.json"


def get_config_path() -> str:
    return os.getenv("MODEL_SERVICE_CONFIG", str(DEFAULT_CONFIG))

app = FastAPI(title="OpenFoodFacts KMeans Model Service")


class PredictRequest(BaseModel):
    model_path: str | None = None
    input_path: str | None = None
    output_path: str | None = None


@app.get("/health")
def health():
    cfg = load_config(get_config_path())
    model_info = (cfg.base_dir / cfg.data.model_root / "model_info.json").resolve()

    return {
        "status": "ok" if model_info.exists() else "model_missing",
        "model_info": str(model_info),
    }


@app.post("/predict")
def predict(request: PredictRequest):
    cfg = load_config(get_config_path())
    service = FoodClusterService(cfg)

    service.predict(
        model_path=request.model_path or cfg.data.model_root,
        input_path=request.input_path,
        output_path=request.output_path,
        keep_alive=True,
    )

    output_path = (cfg.base_dir / (request.output_path or cfg.data.predictions_csv_path)).resolve()
    return {
        "status": "done",
        "output_path": str(output_path),
    }
