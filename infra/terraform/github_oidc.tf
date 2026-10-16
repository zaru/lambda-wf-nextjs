# GitHub の OIDC プロバイダはアカウントに 1 つだけで、既存プロジェクトの Terraform が管理している。
# プロバイダ自体は特定のリポジトリに紐づかない（許可するリポジトリはロールの信頼ポリシーで決まる）ので、参照して共用する
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  web_function_arn = "arn:aws:lambda:${var.region}:${local.account_id}:web-function/${var.web_function_name}"
}

data "aws_iam_policy_document" "github_deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # main ブランチのワークフローだけに許可する
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.project}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid = "UploadArtifacts"
    actions = [
      "s3:PutObject",
      # revision の作成時に、Lambda は呼び出し元の権限でパッケージを読む
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid = "ManageWebFunction"
    # 作成・取得、revision、エンドポイント、リソースポリシーの操作。対象はこの関数だけに絞る
    actions = [
      "lambda:*WebFunction*",
      "lambda:PutResourcePolicy",
      "lambda:GetResourcePolicy",
      "lambda:TagResource",
      "lambda:ListTags",
    ]
    resources = [local.web_function_arn, "${local.web_function_arn}/*"]
  }

  statement {
    sid       = "ReadWebAccountSettings"
    actions   = ["lambda:GetWebAccountSettings"]
    resources = ["*"]
  }

  statement {
    sid = "UseNetworkConnector"
    # デプロイ時に最新のバージョン付き ARN を調べ、revision に渡す
    actions = [
      "lambda:GetNetworkConnector",
      "lambda:PassNetworkConnector",
    ]
    resources = [
      aws_lambdacore_network_connector.web.arn,
      "${aws_lambdacore_network_connector.web.arn}:*",
    ]
  }

  statement {
    sid       = "PassExecutionRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.web_function.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-web-function"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
