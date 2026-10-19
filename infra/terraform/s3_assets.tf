# Next.js の静的ファイル（/_next/static/*）の置き場所。CloudFront が S3 から直接配信する。
# ファイル名にビルドごとのハッシュが入るので、旧ビルドのファイルは消さずに残す
# （デプロイ中に新旧の revision が混ざっても、旧 HTML が参照するチャンクが 404 にならない）。
# バージョニングは不要（オブジェクトのバージョンを参照する revision がないため）
resource "aws_s3_bucket" "assets" {
  bucket = "${var.project}-assets-${local.account_id}"

  # 検証用なので、destroy のときに中身ごと消せるようにする
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "assets" {
  # CloudFront（OAC）からの読み取りは、このディストリビューションだけに許可する
  dynamic "statement" {
    for_each = local.enable_cloudfront ? [1] : []

    content {
      sid       = "AllowCloudFrontOAC"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.assets.arn}/_next/static/*"]

      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceArn"
        values   = [aws_cloudfront_distribution.app[0].arn]
      }
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id
  policy = data.aws_iam_policy_document.assets.json

  depends_on = [aws_s3_bucket_public_access_block.assets]
}
