import logging

from myad_server.logs import log_request


def test_request_log_contains_only_allowlisted_metadata(caplog):
    with caplog.at_level(logging.INFO, logger="myad.access"):
        log_request("request-test-1", "/v1/ask", 200, 3.5, {"candidates": 2, "claims": 1})
    message = caplog.records[-1].getMessage()
    assert message == "request_id=request-test-1 route=/v1/ask status=200 latency_ms=3.5 counts=candidates:2,claims:1"
    for forbidden in ("utterance", "address", "latitude", "longitude", "request_body", "response_body"):
        assert forbidden not in message
