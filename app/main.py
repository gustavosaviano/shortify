from fastapi import FastAPI, HTTPException, Depends
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, HttpUrl
from sqlalchemy.orm import Session
import random, string, logging, json, time
from datetime import datetime

from .database import get_db, engine
from .models import Base, Link

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

Base.metadata.create_all(bind=engine)
app = FastAPI(title="Shortify", version="1.0.0")


class ShortenRequest(BaseModel):
    url: HttpUrl


class ShortenResponse(BaseModel):
    short_code: str
    short_url: str
    original_url: str


def generate_code(length=6):
    return "".join(random.choices(string.ascii_letters + string.digits, k=length))


@app.get("/health")
def health():
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}


@app.get("/metrics")
def metrics(db: Session = Depends(get_db)):
    count = db.query(Link).count()
    return {"total_links": count, "timestamp": datetime.utcnow().isoformat()}


@app.post("/shorten", response_model=ShortenResponse)
def shorten(req: ShortenRequest, db: Session = Depends(get_db)):
    start = time.time()
    code = generate_code()
    while db.query(Link).filter(Link.short_code == code).first():
        code = generate_code()
    link = Link(short_code=code, original_url=str(req.url))
    db.add(link)
    db.commit()
    db.refresh(link)
    duration_ms = round((time.time() - start) * 1000, 2)
    logger.info(json.dumps({"event": "link_created", "short_code": code, "duration_ms": duration_ms}))
    return ShortenResponse(
        short_code=code,
        short_url=f"http://localhost:8000/{code}",
        original_url=str(req.url),
    )


@app.get("/{code}")
def redirect(code: str, db: Session = Depends(get_db)):
    link = db.query(Link).filter(Link.short_code == code).first()
    if not link:
        raise HTTPException(status_code=404, detail="Link not found")
    link.clicks += 1
    db.commit()
    logger.info(json.dumps({"event": "link_clicked", "short_code": code, "clicks": link.clicks}))
    return RedirectResponse(url=link.original_url, status_code=302)
