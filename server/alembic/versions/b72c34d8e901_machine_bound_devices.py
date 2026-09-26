"""Bind upgraded devices to a hashed machine identity; legacy rows stay unbound."""
from alembic import op
import sqlalchemy as sa
revision = "b72c34d8e901"
down_revision = "d8e6f3a19b25"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("devices", sa.Column("machine_fingerprint", sa.String(64), nullable=True))

def downgrade():
    op.drop_column("devices", "machine_fingerprint")
