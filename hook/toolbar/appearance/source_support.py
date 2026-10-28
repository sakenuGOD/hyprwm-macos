"""Source-only appearance dependencies; importing this module performs no effects."""
import importlib.util
import os
from pathlib import Path
import tempfile

# Resolve the existing public toolbar helpers from this source directory.
_companion_path = Path(__file__).resolve().parents[1] / 'native_companion.py'
_spec = importlib.util.spec_from_file_location('_hyprwm_appearance_source_companion', _companion_path)
_companion = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_companion)
read = _companion.read
contract = _companion.contract

# Byte-equal function from palette/engine.py. Its bytes API differs from the
# toolbar loader's JSON atomic helper; preserve that original contract here.
def atomic(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    if path.exists() and path.read_bytes()==data:return False
    mode=path.stat().st_mode&0o777 if path.exists() else 0o600
    fd,name=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(name,mode);os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)
    return True
