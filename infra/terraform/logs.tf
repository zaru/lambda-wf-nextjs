# Web Function は、リージョン内のログを <name>.local に書き、
# ホームリージョンの <name> に集約する。両方とも保持期間を決めて先に作っておく
resource "aws_cloudwatch_log_group" "web_function" {
  name              = "/aws/lambda/web/${var.web_function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "web_function_local" {
  name              = "/aws/lambda/web/${var.web_function_name}.local"
  retention_in_days = 30
}
