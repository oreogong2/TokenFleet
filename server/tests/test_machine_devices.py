from __future__ import annotations
import json,time,uuid
from datetime import timedelta
from sqlalchemy import select,func
from app.models import Device,EnrollmentToken,User,DailyUsage,utcnow
from app.security import sign_device_request

A = "a" * 64
B = "b" * 64
PATH = "/api/v1/devices/me/enrollment-tokens"

def signed(h, device, path, payload, fingerprint=None, *, signed_fingerprint=None):
    body=json.dumps(payload,sort_keys=True,separators=(",", ":")).encode()
    timestamp=str(int(time.time()));nonce=str(uuid.uuid4())
    signature=sign_device_request(device_secret=device.secret,timestamp_text=timestamp,
        nonce=nonce,method="POST",path=path,body=body,
        machine_fingerprint=fingerprint if signed_fingerprint is None else signed_fingerprint)
    headers={"X-Device-ID":device.id,"X-Timestamp":timestamp,"X-Nonce":nonce,
             "X-Signature":signature,"Content-Type":"application/json"}
    if fingerprint is not None:headers["X-Machine-Fingerprint"]=fingerprint
    return h.client.post(path,content=body,headers=headers)

def enroll_payload(code, fingerprint, public_id=None):
    return {"enrollment_token":code,"device_public_id":public_id or str(uuid.uuid4()),
        "platform":"windows","app_version":"0.1.0-beta.13","collector_version":"0.2.0",
        "machine_fingerprint":fingerprint}

def first(h):return h.enroll(admin_name="a_admin",user_name="a_member")

def test_legacy_upgrade_binds_once_and_blocks_cloned_state(harness):
    h=harness;d=first(h);payload=h.usage_payload()
    assert h.signed_post(d,payload).status_code==200
    assert signed(h,d,"/api/v1/usage/daily",payload,A).status_code==200
    with h.session_factory() as s:
        assert s.get(Device,d.id).machine_fingerprint==A
        before=[(r.id,r.input_tokens,r.output_tokens,r.cache_read_tokens,r.cache_write_tokens)
                for r in s.scalars(select(DailyUsage))]
    changed=json.loads(json.dumps(payload));changed["buckets"][0]["input_tokens"]=9999
    r=signed(h,d,"/api/v1/usage/daily",changed,B)
    assert r.status_code==409 and r.json()["detail"]["code"]=="machine_mismatch"
    r=h.signed_post(d,changed)
    assert r.status_code==409 and r.json()["detail"]["code"]=="machine_binding_required"
    with h.session_factory() as s:
        assert s.get(Device,d.id).machine_fingerprint==A
        assert before==[(r.id,r.input_tokens,r.output_tokens,r.cache_read_tokens,r.cache_write_tokens)
                        for r in s.scalars(select(DailyUsage))]

def test_fingerprint_header_is_covered_by_signature(harness):
    d=first(harness);r=signed(harness,d,"/api/v1/usage/daily",harness.usage_payload(),B,signed_fingerprint=A)
    assert r.status_code==401
    with harness.session_factory() as s:assert s.get(Device,d.id).machine_fingerprint is None

def test_wrong_machine_enrollment_preserves_secret_and_code(harness):
    h=harness;d=first(h);assert signed(h,d,"/api/v1/usage/daily",h.usage_payload(),A).status_code==200
    r=signed(h,d,PATH,{},A);assert r.status_code==201;code=r.json()["enrollment_token"]
    bad=h.client.post("/api/v1/devices/enroll",json=enroll_payload(code,B,d.public_id))
    assert bad.status_code==409
    # Original secret still works, and the failed request did not consume the code.
    assert signed(h,d,"/api/v1/usage/daily",h.usage_payload(),A).status_code==200
    assert h.client.post("/api/v1/devices/enroll",json=enroll_payload(code,B)).status_code==201

def test_second_device_reuses_member_and_sums_own_usage(harness):
    h=harness;d=first(h)
    with h.session_factory() as s:users=s.scalar(select(func.count()).select_from(User))
    r=signed(h,d,PATH,{},A);assert r.status_code==201 and r.headers["cache-control"]=="no-store"
    code=r.json()["enrollment_token"];new=h.client.post("/api/v1/devices/enroll",json=enroll_payload(code,B))
    assert new.status_code==201;v=new.json()
    from tests.conftest import EnrolledDevice
    second=EnrolledDevice(id=v["device_id"],public_id=v["device_public_id"],secret=v["device_secret"],user_id=d.user_id)
    a=h.usage_payload();b=h.usage_payload();b["buckets"][0]["input_tokens"]=240
    assert signed(h,d,"/api/v1/usage/daily",a,A).status_code==200
    assert signed(h,second,"/api/v1/usage/daily",b,B).status_code==200
    with h.session_factory() as s:
        assert s.scalar(select(func.count()).select_from(User))==users
        devices=list(s.scalars(select(Device).where(Device.user_id==d.user_id)))
        assert len(devices)==2 and {x.machine_fingerprint for x in devices}=={A,B}
        rows=list(s.scalars(select(DailyUsage).where(DailyUsage.user_id==d.user_id)))
        assert len(rows)==2 and sum(x.input_tokens for x in rows)==360
    assert h.client.post("/api/v1/devices/enroll",json=enroll_payload(code,B)).status_code==400

def test_self_service_cannot_choose_another_member_or_issue_when_disabled(harness):
    h=harness;d=first(h)
    r=signed(h,d,PATH,{"user_id":str(uuid.uuid4())},A);assert r.status_code==422
    with h.session_factory() as s:
        device=s.get(Device,d.id);device.is_active=False;s.commit()
    assert signed(h,d,PATH,{},A).status_code==403

def test_reissue_expires_previous_code_and_keeps_consumed_history(harness):
    h=harness;d=first(h);first_code=signed(h,d,PATH,{},A).json()["enrollment_token"]
    second=signed(h,d,PATH,{},A);assert second.status_code==201
    assert h.client.post("/api/v1/devices/enroll",json=enroll_payload(first_code,B)).status_code==400
    with h.session_factory() as s:
        row=s.scalar(select(EnrollmentToken).where(EnrollmentToken.user_id==d.user_id,
            EnrollmentToken.used_at.is_(None),EnrollmentToken.expires_at>utcnow()))
        row.expires_at=utcnow()-timedelta(seconds=1);s.commit()
    assert h.client.post("/api/v1/devices/enroll",json=enroll_payload(second.json()["enrollment_token"],B)).status_code==400
