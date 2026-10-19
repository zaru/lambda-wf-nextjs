# GitHub リポジトリの Variables に登録する値（いずれも秘密情報ではない）

output "github_variables" {
  description = "GitHub の Repository variables に登録する値"
  value = merge(
    {
      AWS_REGION            = var.region
      AWS_DEPLOY_ROLE_ARN   = aws_iam_role.github_deploy.arn
      ARTIFACT_BUCKET       = aws_s3_bucket.artifacts.bucket
      ASSETS_BUCKET         = aws_s3_bucket.assets.bucket
      WEB_FUNCTION_NAME     = var.web_function_name
      WEB_FUNCTION_ROLE_ARN = aws_iam_role.web_function.arn
      NETWORK_CONNECTOR_ARN = aws_lambdacore_network_connector.web.arn
      VALKEY_HOST           = aws_elasticache_serverless_cache.main.endpoint[0].address
      VALKEY_PORT           = tostring(aws_elasticache_serverless_cache.main.endpoint[0].port)
      VALKEY_USERNAME       = aws_elasticache_user.app.user_name
      VALKEY_SECRET_ARN     = aws_secretsmanager_secret.valkey_app_password.arn
      APP_DOMAIN            = var.domain_name
    },
    local.enable_cloudfront ? {
      DISTRIBUTION_ARN = aws_cloudfront_distribution.app[0].arn
      APP_URL          = "https://${var.domain_name}"
    } : {},
  )
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway の送信元 IP（外部通信の確認に使う）"
  value       = aws_eip.nat.public_ip
}

output "cloudfront_domain_name" {
  description = "CloudFront のドメイン名（2 回目の apply 後）"
  value       = local.enable_cloudfront ? aws_cloudfront_distribution.app[0].domain_name : null
}
