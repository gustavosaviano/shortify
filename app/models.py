from sqlalchemy import Column, String, Integer, DateTime
from sqlalchemy.sql import func
from .database import Base


class Link(Base):
    __tablename__ = "links"

    short_code = Column(String(10), primary_key=True, index=True)
    original_url = Column(String(2048), nullable=False)
    clicks = Column(Integer, default=0)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
