# Jewelers Mutual Clone – Jewelry Insurance Quote Website

This repository contains a minimal **serverless clone** of the Jewelers Mutual website focused on quoting jewelry insurance.  The goal is to demonstrate how you can build an event‑driven web application on AWS using Python, Terraform, GitHub Actions and Datadog instrumentation.  The site provides a simple home page with a link to a quote form.  When a visitor submits the form, the quote workflow is orchestrated via **AWS Step Functions**, with messages being published to **SNS** and queued in **SQS** for downstream processing.  All of the infrastructure is defined as code with Terraform and can be deployed automatically using GitHub Actions.

## Project layout

```
jewelers_mutual_clone/
├── README.md              # this file
├── frontend/              # simple website served via API Gateway
│   ├── index.html         # home page with a description and quote form
│   └── styles.css         # basic styling for the site
├── backend/               # Python code for AWS Lambda functions
│   ├── compute_quote.py   # Lambda used by Step Functions to calculate premiums
│   └── quote_api.py       # Lambda exposed via API Gateway to start the workflow
├── terraform/             # Infrastructure as Code definitions
│   ├── main.tf            # AWS resources (Lambda, API Gateway, SQS, SNS, Step Functions)
│   ├── variables.tf       # configuration variables
│   └── outputs.tf         # exported values (API endpoint, queue/topic ARNs)
└── .github/workflows/
    └── ci.yml             # GitHub Actions workflow for CI/CD
```

## How it works

1. **User experience.** The home page (`frontend/index.html`) introduces the service and links to a quote form.  The form collects a customer’s name, email and jewellery value and posts that data to the serverless API.  If you are running locally you can open the HTML directly in a browser or deploy it behind API Gateway.

2. **API Lambda (`quote_api.py`).** When the quote form is submitted, API Gateway invokes the `quote_api` Lambda.  This function reads the request payload, then starts a **synchronous execution** of an **AWS Step Functions Express** state machine.  The state machine runs the entire quote workflow (computing the premium, publishing to SNS, queueing in SQS) and immediately returns the calculated premium to the caller.  Once complete, `quote_api` responds with a JSON body containing the premium.

3. **Workflow orchestration.**  The Step Functions state machine defined in `terraform/main.tf` consists of four states:

   * **`ComputeQuote`** – a `Task` state that invokes the `compute_quote` Lambda to calculate the premium.  The premium is a simple percentage (1 %) of the declared jewellery value.  The compute function sends a custom metric to Datadog for observability using the `datadog_lambda.metric.lambda_metric` function【290555705275488†L993-L1038】.
   * **`PublishToSNS`** – a `Task` state using the direct SNS integration to publish a message to an SNS topic.  The message contains the customer name, email, jewellery value and calculated premium.  Using SNS allows the application to **broadcast** the quote event to multiple subscribers【661101742499715†L141-L151】.
   * **`SendToSQS`** – another `Task` state using the direct SQS integration to enqueue the same data into an SQS queue.  SQS provides **point‑to‑point** asynchronous communication【661101742499715†L130-L139】 and is ideal for decoupling downstream processing.
   * **`ReturnQuote`** – a `Pass` state that extracts the premium from the previous state’s result and makes it the output of the state machine.  Because we use an **Express** state machine, the `quote_api` Lambda can call `StartSyncExecution` and immediately receive the result.

4. **Infrastructure.**  The `terraform/` directory declares all AWS resources required to run the site: Lambda functions, IAM roles and policies, SQS queue, SNS topic, Step Functions state machine (Express), API Gateway HTTP API, and log groups.  When you apply the Terraform plan the API endpoint will be output to the console.

5. **Datadog integration.**  The `compute_quote.py` function demonstrates how to send a custom metric to Datadog using the `datadog_lambda` library.  When the quote is calculated the function calls `lambda_metric('quote.premium', premium, tags=[...])`.  You will need to provide a Datadog API key and enable the Datadog Lambda extension or layer when deploying to AWS.  For guidance on creating custom metrics with `lambda_metric` see the example on Stack Overflow【290555705275488†L993-L1038】.  If you don’t supply a Datadog key the metric call will simply do nothing.

## Deploying the application

### Prerequisites

* **AWS CLI** configured with credentials that have permission to create Lambda, API Gateway, SQS, SNS, IAM and Step Functions resources in the region specified (default `us-east-1`).
* **Terraform v1.5+** installed locally.  The provided configuration uses Terraform to provision infrastructure.
* **Python 3.9+** for developing and packaging the Lambda functions.  If you plan to package dependencies (e.g. Datadog), you may need to build the deployment zip using a Linux environment.

### Steps

1. **Install dependencies** (optional).  To instrument the compute function with Datadog, install the `datadog-lambda` library and package it with your function.  For example:

   ```bash
   cd backend
   pip install --target python datadog-lambda==2.*  # installs into ./python
   # package the function along with dependencies
   zip -r compute_quote.zip compute_quote.py python
   ```

   If you don’t need Datadog instrumentation you can simply zip the function file.

2. **Initialize and apply Terraform** to deploy the infrastructure.  Ensure your AWS credentials are exported (e.g. via environment variables or an AWS profile).  From the `terraform/` directory run:

   ```bash
   terraform init
   terraform apply -auto-approve
   ```

   Terraform will build all resources and output the API endpoint.  You can then open the `frontend/index.html` in your browser and adjust the `FETCH_URL` constant to point to the API endpoint.

3. **Access the website.**  For local development you may simply double‑click `index.html` and submit a quote.  In production you can host the HTML from S3 or any static host and point it at the API Gateway endpoint.

4. **Monitoring with Datadog.**  After deploying your functions with the Datadog layer and API key you’ll see a custom metric called `quote.premium` in Datadog.  Each invocation will also emit enhanced Lambda metrics automatically.  See the Datadog documentation for further details on serverless monitoring.

### Clean up

To remove all AWS resources created by this project run `terraform destroy` from the `terraform/` directory.  Always destroy resources you no longer need to avoid ongoing charges.

## GitHub Actions CI/CD

The included `.github/workflows/ci.yml` file defines a simple CI/CD pipeline that checks out the repository, installs Python dependencies, runs a lint/test stage (currently placeholder), and then initializes and applies the Terraform configuration.  In a real project you would restrict `terraform apply` to protected branches or use different stages for plan/apply.

## Next steps

* **Expand the front‑end.**  Enhance the look and feel of the site by adding more pages, images, or using a CSS framework.  The current pages are intentionally minimal.
* **Secure the API.**  Add authentication (e.g. AWS Cognito or API keys) to the API Gateway.
* **Add downstream processing.**  Subscribe additional Lambdas or services to the SNS topic and SQS queue to handle quotes asynchronously (e.g. send confirmation emails, persist to a database).
* **Attach your Datadog account.**  Provide your API key and set up the Datadog forwarder layer so that metrics, logs, and traces flow into Datadog.
# Jewelers
