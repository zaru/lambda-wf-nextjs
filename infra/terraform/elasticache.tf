# アプリ用ユーザーのパスワード。値は state に平文で残るので、state はコミットしない
resource "random_password" "valkey_app" {
  length  = 40
  special = false
}

resource "aws_elasticache_user" "app" {
  user_id   = "${var.project}-app"
  user_name = "${var.project}-app"
  engine    = "valkey"

  # アプリが使うキー（ハッシュタグ {todo} 付き）とチャネルだけを許可し、
  # FLUSHALL などキーを持たない危険なコマンドは禁止する
  access_string = "on ~{todo}:* &* +@all -@dangerous"

  authentication_mode {
    type      = "password"
    passwords = [random_password.valkey_app.result]
  }
}

# Valkey エンジンのユーザーグループには default ユーザーは不要（Redis OSS エンジンでは必須）
resource "aws_elasticache_user_group" "app" {
  user_group_id = "${var.project}-users"
  engine        = "valkey"
  user_ids      = [aws_elasticache_user.app.user_id]
}

resource "aws_elasticache_serverless_cache" "main" {
  name                 = "${var.project}-valkey"
  engine               = "valkey"
  major_engine_version = var.valkey_major_engine_version
  description          = "Lambda Web Functions verification"

  subnet_ids         = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids = [aws_security_group.valkey.id]
  user_group_id      = aws_elasticache_user_group.app.user_group_id

  # 03:00 JST に日次スナップショットを取り、7 日間保持する
  daily_snapshot_time      = "18:00"
  snapshot_retention_limit = 7

  cache_usage_limits {
    data_storage {
      maximum = var.valkey_max_data_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.valkey_max_ecpu_per_second
    }
  }
}
