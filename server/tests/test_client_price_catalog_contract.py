"""Cross-language golden fixture; all rates are synthetic, not price evidence."""
from datetime import date
from decimal import Decimal
import hashlib
import json
from pathlib import Path

from app.models import PriceVersion
from app.pricing import normalize_model
from app.schemas import UsageBucket
from app.services import derived_cost_microunits


def test_python_and_swift_share_catalog_hash_aliases_dates_and_half_up_units():
    fixture = Path(__file__).resolve().parents[2] / 'TokenStepSwift/Tests/Fixtures/server-price-catalog-v1.json'
    body = json.loads(fixture.read_text())
    claimed = body.pop('version')
    assert hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest() == claimed
    assert body['schema_version'] == body['normalization_version'] == 1
    assert normalize_model('openai/gpt_6_sol-20260102') == 'gpt-6-sol'
    assert normalize_model('Anthropic/claude_fable_5-1-20260901') == 'claude-fable-5.1'
    assert normalize_model('gpt-6-sol-20260230') == 'gpt-6-sol-20260230'
    row = body['prices'][1]
    price = PriceVersion(**{k: Decimal(row[k]) for k in ('input_per_million', 'output_per_million', 'cache_read_per_million', 'cache_write_per_million')})
    for inputs, expected in [(1, 2), (2, 3), (3, 5)]:
        bucket = UsageBucket(date=date(2026, 9, 26), timezone='Asia/Shanghai', tool='Codex', model='gpt-6-sol',
                            source='local', input_tokens=inputs, output_tokens=0, cache_read_tokens=0,
                            cache_write_tokens=0, completeness='exact')
        assert derived_cost_microunits(bucket, price) == expected
