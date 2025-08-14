output "api_endpoint" {
  description = "Invoke URL for the quote API"
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "sqs_queue_url" {
  description = "URL of the SQS queue that receives quote events"
  value       = aws_sqs_queue.quote_queue.id
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic that receives quote events"
  value       = aws_sns_topic.quote_topic.arn
}

output "step_function_arn" {
  description = "ARN of the Step Functions state machine"
  value       = aws_sfn_state_machine.quote_state_machine.arn
}