# CloudFront のオリジンには Web Function のエンドポイントのホスト名が必要。
# エンドポイントは GitHub Actions の初回デプロイで作られるので、
# web_function_endpoint_domain を設定した 2 回目の apply で作る
locals {
  enable_cloudfront = var.web_function_endpoint_domain != ""
  origin_id         = "web-function"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Web Function のエンドポイントは Host でルーティングするため、ビューワーの Host は転送しない
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "web_function" {
  count = local.enable_cloudfront ? 1 : 0

  name                              = "${var.project}-web-function"
  description                       = "Lambda Web Function origin"
  origin_access_control_origin_type = "lambda"
  # Web Function のオリジンが対応しているのは always-amz-auth だけ
  signing_behavior = "always-amz-auth"
  # HomeRegion エンドポイント（リージョナル）なので sigv4
  signing_protocol = "sigv4"
}

resource "aws_cloudfront_distribution" "app" {
  count = local.enable_cloudfront ? 1 : 0

  enabled         = true
  comment         = "${var.project} Lambda Web Functions verification"
  aliases         = [var.domain_name]
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_200"

  origin {
    origin_id                = local.origin_id
    domain_name              = var.web_function_endpoint_domain
    origin_access_control_id = aws_cloudfront_origin_access_control.web_function[0].id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      # Web Function のタイムアウト（30 秒）に合わせる
      origin_read_timeout = 30
    }
  }

  # 動的なページと Server Actions はキャッシュしない
  default_cache_behavior {
    target_origin_id         = local.origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
  }

  # Next.js のビルド成果物（ファイル名にハッシュが入る）はエッジでキャッシュする
  ordered_cache_behavior {
    path_pattern           = "/_next/static/*"
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_route53_record" "app" {
  for_each = local.enable_cloudfront ? toset(["A", "AAAA"]) : toset([])

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.app[0].domain_name
    zone_id                = aws_cloudfront_distribution.app[0].hosted_zone_id
    evaluate_target_health = false
  }
}
