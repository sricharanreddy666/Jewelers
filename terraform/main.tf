terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.2"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

############################
# Package Lambda functions #
############################

# Compress the compute_quote lambda into a zip on the fly.
data "archive_file" "compute_quote" {
  type        = "zip"
  source_file = "${path.module}/../backend/compute_quote.py"
  output_path = "${path.module}/../backend/compute_quote.zip"
}

# Compress the quote_api lambda.
data "archive_file" "quote_api" {
  type        = "zip"
  source_file = "${path.module}/../backend/quote_api.py"
  output_path = "${path.module}/../backend/quote_api.zip"
}

##########################
# Messaging resources    #
##########################

resource "aws_sqs_queue" "quote_queue" {
  name = "${var.project_name}-queue"
}

resource "aws_sns_topic" "quote_topic" {
  name = "${var.project_name}-topic"
}

##########################
# IAM Roles and Policies #
##########################

# Execution role for compute_quote Lambda
data "aws_iam_policy_document" "compute_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "compute_role" {
  name               = "${var.project_name}-compute-role"
  assume_role_policy = data.aws_iam_policy_document.compute_assume_role.json
}

# Basic execution policy for compute lambda: write logs and send metrics (metrics via custom code doesn't require permissions)
data "aws_iam_policy_document" "compute_policy" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "compute_role_policy" {
  name   = "${var.project_name}-compute-policy"
  role   = aws_iam_role.compute_role.id
  policy = data.aws_iam_policy_document.compute_policy.json
}

# Execution role for quote_api Lambda
data "aws_iam_policy_document" "api_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api_role" {
  name               = "${var.project_name}-api-role"
  assume_role_policy = data.aws_iam_policy_document.api_assume_role.json
}

# Policy allowing the API lambda to write logs and invoke Step Functions
data "aws_iam_policy_document" "api_policy" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
  statement {
    effect   = "Allow"
    actions  = ["states:StartSyncExecution"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "api_role_policy" {
  name   = "${var.project_name}-api-policy"
  role   = aws_iam_role.api_role.id
  policy = data.aws_iam_policy_document.api_policy.json
}

# Role for Step Functions state machine
data "aws_iam_policy_document" "sfn_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_role" {
  name               = "${var.project_name}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json
}

# Allow Step Functions to invoke Lambda, publish to SNS and send to SQS
data "aws_iam_policy_document" "sfn_policy" {
  statement {
    effect = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.compute_lambda.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.quote_topic.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.quote_queue.arn]
  }
}

resource "aws_iam_role_policy" "sfn_role_policy" {
  name   = "${var.project_name}-sfn-policy"
  role   = aws_iam_role.sfn_role.id
  policy = data.aws_iam_policy_document.sfn_policy.json
}

##########################
# Lambda Functions       #
##########################

resource "aws_lambda_function" "compute_lambda" {
  function_name = "${var.project_name}-compute"
  role          = aws_iam_role.compute_role.arn
  handler       = "compute_quote.lambda_handler"
  runtime       = "python3.9"
  filename      = data.archive_file.compute_quote.output_path
  source_code_hash = filebase64sha256(data.archive_file.compute_quote.output_path)
  timeout       = 10
  environment {
    variables = {
      # reserved for future environment configuration
    }
  }
}

resource "aws_lambda_function" "quote_api_lambda" {
  function_name = "${var.project_name}-api"
  role          = aws_iam_role.api_role.arn
  handler       = "quote_api.lambda_handler"
  runtime       = "python3.9"
  filename      = data.archive_file.quote_api.output_path
  source_code_hash = filebase64sha256(data.archive_file.quote_api.output_path)
  timeout       = 20
  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.quote_state_machine.arn
    }
  }
}

##################################
# Step Functions State Machine   #
##################################

resource "aws_sfn_state_machine" "quote_state_machine" {
  name     = "${var.project_name}-workflow"
  role_arn = aws_iam_role.sfn_role.arn
  type     = "EXPRESS"
  definition = jsonencode({
    Comment = "Jewelry insurance quote workflow"
    StartAt = "ComputeQuote"
    States = {
      ComputeQuote = {
        Type     = "Task"
        Resource = aws_lambda_function.compute_lambda.arn
        InputPath = "$"
        ResultPath = "$.quoteResult"
        Next     = "PublishToSNS"
      }
      PublishToSNS = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.quote_topic.arn
          Message = {
            "quote.$" = "$.quoteResult.Payload.quote"
            "name.$"  = "$.name"
            "email.$" = "$.email"
            "value.$" = "$.value"
          }
          Subject = "New Jewelry Insurance Quote"
        }
        ResultPath = "$.sns"
        Next = "SendToSQS"
      }
      SendToSQS = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl = aws_sqs_queue.quote_queue.id
          MessageBody = {
            "quote.$" = "$.quoteResult.Payload.quote"
            "name.$"  = "$.name"
            "email.$" = "$.email"
            "value.$" = "$.value"
          }
        }
        ResultPath = "$.sqs"
        Next = "ReturnQuote"
      }
      ReturnQuote = {
        Type = "Pass"
        Parameters = {
          "quote.$" = "$.quoteResult.Payload.quote"
        }
        End = true
      }
    }
  })
}

##########################
# API Gateway            #
##########################

resource "aws_apigatewayv2_api" "api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_integration" "api_integration" {
  api_id                = aws_apigatewayv2_api.api.id
  integration_type      = "AWS_PROXY"
  integration_uri       = aws_lambda_function.quote_api_lambda.invoke_arn
  integration_method    = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "api_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /quote"
  target    = "integrations/${aws_apigatewayv2_integration.api_integration.id}"
}

resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.quote_api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}