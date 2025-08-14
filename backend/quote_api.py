"""
API Lambda entry point used by API Gateway.

This function receives HTTP POST requests from the quote form on the
frontend.  It extracts the customer name, email and jewellery value from
the request body, then kicks off a synchronous execution of the Step
Functions Express state machine that performs the quote workflow.  The
state machine returns the calculated premium, which is forwarded to the
client as a JSON response.  Datadog metrics are emitted for observability.
"""

import json
import os
from typing import Any, Dict

import boto3  # AWS SDK for Python

try:
    from datadog_lambda.metric import lambda_metric
except Exception:
    lambda_metric = None  # type: ignore


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Entry point for the Lambda.

    Parameters
    ----------
    event: dict
        The API Gateway HTTP event.  The JSON body is expected to contain
        `name`, `email` and `value` fields.
    context:
        Lambda runtime context (unused).

    Returns
    -------
    dict
        A response object compatible with API Gateway HTTP API, with keys
        `statusCode`, `headers` and `body`.
    """
    # Emit a metric for inbound requests
    if lambda_metric:
        try:
            lambda_metric("quote.request", 1, tags=["app:jewelers-mutual-clone"])
        except Exception:
            pass

    # Parse the body (JSON)
    body = event.get("body") or "{}"
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return _response(400, {"message": "Invalid JSON payload"})

    # Validate required fields
    name = data.get("name")
    email = data.get("email")
    value = data.get("value")
    if not name or not email or value is None:
        return _response(400, {"message": "Missing name, email or value"})

    # Kick off the step function execution synchronously
    state_machine_arn = os.environ.get("STATE_MACHINE_ARN")
    if not state_machine_arn:
        return _response(500, {"message": "Server not configured"})

    sf = boto3.client("stepfunctions")
    input_payload = {
        "name": name,
        "email": email,
        "value": value,
    }
    try:
        # StartSyncExecution is only supported for Express workflows.
        resp = sf.start_sync_execution(
            stateMachineArn=state_machine_arn,
            input=json.dumps(input_payload),
        )
    except Exception as exc:
        # Log and return error
        return _response(500, {"message": f"Failed to start workflow: {str(exc)}"})

    # Parse the output from the state machine
    output_str = resp.get("output")
    if not output_str:
        return _response(500, {"message": "No output from workflow"})
    try:
        output_data = json.loads(output_str)
    except json.JSONDecodeError:
        return _response(500, {"message": "Malformed workflow output"})

    quote = output_data.get("quote")
    if quote is None:
        return _response(500, {"message": "Workflow did not return a quote"})

    return _response(200, {"quote": quote})


def _response(status: int, body: Dict[str, Any]) -> Dict[str, Any]:
    """Helper to format HTTP responses.

    Parameters
    ----------
    status: int
        HTTP status code.
    body: dict
        Response body to be JSON-serialised.

    Returns
    -------
    dict
        A response object for API Gateway.
    """
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
        "body": json.dumps(body),
    }


# Alias for AWS Lambda runtime
lambda_handler = handler