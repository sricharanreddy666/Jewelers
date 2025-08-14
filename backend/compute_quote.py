"""
AWS Lambda function that calculates a jewellery insurance premium.

This function is invoked by the Step Functions state machine.  It expects an
event payload containing a numeric `value` field representing the insured
jewel's value in USD.  The premium is calculated as a flat 1 % of the value
and returned in the response payload.  The function also submits a custom
metric to Datadog using the `lambda_metric` helper from the datadog-lambda
library.  If the library is not available (for example when Datadog isn't
configured) the metric submission is simply skipped.

Example input event::

    {
      "name": "Alice",
      "email": "alice@example.com",
      "value": 5000
    }

Example response::

    {
      "quote": 50.0
    }

"""

import json
from typing import Any, Dict

try:
    # Attempt to import the Datadog metric helper.  If Datadog is not
    # configured this import will fail silently.
    from datadog_lambda.metric import lambda_metric
except Exception:
    lambda_metric = None  # type: ignore


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Calculate the insurance premium and emit a Datadog metric.

    Parameters
    ----------
    event: dict
        The input event containing at least a `value` key.  Additional fields
        such as `name` and `email` are passed through untouched.
    context:
        Lambda runtime context (unused).

    Returns
    -------
    dict
        A dictionary with a single `quote` field containing the calculated
        premium as a float.
    """
    # Defensive parsing of the value; default to 0 if missing or invalid
    value = event.get("value")
    try:
        numeric_value = float(value)
    except (TypeError, ValueError):
        numeric_value = 0.0

    # Calculate premium: 1 % of declared value
    premium = round(numeric_value * 0.01, 2)

    # Send a custom metric to Datadog if available.  The metric name and
    # tags can be adjusted to suit your Datadog dashboards.  By default
    # Datadog treats metrics created with ``lambda_metric`` as gauges【290555705275488†L993-L1038】.
    if lambda_metric:
        try:
            lambda_metric(
                "quote.premium",
                premium,
                tags=[
                    "app:jewelers-mutual-clone",
                    f"customer:{event.get('name', 'unknown')}",
                ],
            )
        except Exception:
            # Swallow any errors to avoid failing the Lambda execution
            pass

    return {"quote": premium}


# Alias for AWS Lambda runtime
lambda_handler = handler