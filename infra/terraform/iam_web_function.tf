# Web Function のコードが引き受ける実行ロール
data "aws_iam_policy_document" "web_function_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "web_function" {
  name               = "${var.project}-web-function"
  assume_role_policy = data.aws_iam_policy_document.web_function_assume.json
}

data "aws_iam_policy_document" "web_function" {
  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.web_function.arn}:*",
      "${aws_cloudwatch_log_group.web_function_local.arn}:*",
    ]
  }

  statement {
    sid       = "ReadValkeyPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.valkey_app_password.arn]
  }
}

resource "aws_iam_role_policy" "web_function" {
  name   = "web-function"
  role   = aws_iam_role.web_function.id
  policy = data.aws_iam_policy_document.web_function.json
}
