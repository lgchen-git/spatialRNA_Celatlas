from pathlib import Path
import shlex


ROOT = Path(workflow.basedir).resolve().parent
INPUTS = Path(str(config["inputs_root"])).resolve()
REFERENCE = Path(str(config["reference_root"])).resolve()
OUT = Path(str(config["outputs_root"])).resolve()
LOG = Path(str(config["log_root"])).resolve()
TMP = Path(str(config["tmp_root"])).resolve()

SAMPLE = str(config["sample_id"])
SAMPLE_DIR = OUT / SAMPLE
INPUT_DIR = INPUTS / str(config["input_dir"])
REFERENCE_DIR = REFERENCE / str(config["species"])
REPORT = SAMPLE_DIR / f"{SAMPLE}_spatial_analysis_report.html"
CELLSEG_LABELS = SAMPLE_DIR / "06.segment/02.cellsegment/stardist_inference" / f"{SAMPLE}.stardist_labels.tif"
CELL_MATRIX = SAMPLE_DIR / "06.segment/02.cellsegment/cell_matrix/matrix.mtx.gz"
CELL_METRICS = SAMPLE_DIR / "07.outs/cellsegmented_outputs/metrics_summary.json"


def stage_dir(stage):
    return SAMPLE_DIR / stage


def stage_done(stage):
    return stage_dir(stage) / ".stage.done"


def stage_log(stage):
    return LOG / SAMPLE / f"{stage.replace('/', '_')}.log"


def stage_benchmark(stage):
    return LOG / SAMPLE / f"{stage.replace('/', '_')}.benchmark.txt"


def runner_command(step, stage, check_path=None):
    log_dir = LOG / SAMPLE / "runner" / stage.replace("/", "_")
    args = [
        "celatlas_spatial", "run", "--engine", "python",
        "--pipeline", "denovo", "--workflow", str(config["workflow"]),
        "--chip-number", SAMPLE, "--casno", str(config["run_id"]),
        "--sample-name", str(config["sample_name"]),
        "--tissue", str(config["tissue"]),
        "--chemistry", str(config["chemistry"]),
        "--species", str(config["species"]),
        "--method", str(config["method"]), "--mode", str(config["mode"]),
        "--sampledir", str(SAMPLE_DIR),
        "--fastq-dir", str(INPUT_DIR),
        "--fastq-name", str(config["fastq_name"]),
        "--mask-dir", str(INPUT_DIR), "--image-dir", str(INPUT_DIR),
        "--reference-dir", str(REFERENCE), "--src-dir", "/opt/celatlas/src",
        "--thread", str(config["thread"]),
        "--featurecounts-thread", str(config["featurecounts_thread"]),
        "--bin", str(config["bin"]), "--pixel-size", str(config["pixel_size"]),
        "--cell-num", str(config["cell_num"]),
        "--only-steps", step, "--preflight", "--stage-inputs",
        "--allow-existing-step-outputs", "--log-dir", str(log_dir),
    ]
    if bool(config.get("enable_cell_segmentation", False)):
        args.append("--enable-stardist-cell-segment")
    command = [
        "python3", str(ROOT / "pipeline" / "scripts" / "run_stage.py"),
        "--output-dir", str(stage_dir(stage)),
        "--done", str(stage_done(stage)),
    ]
    if check_path is not None:
        command.extend(["--check-path", str(check_path)])
    command.extend(["--"] + args)
    return shlex.join(str(value) for value in command)
