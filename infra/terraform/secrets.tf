resource "aws_secretsmanager_secret" "valkey_app_password" {
  name        = "${var.project}/valkey/app-password"
  description = "Password of the Valkey user for the web function"

  # 検証用なので、destroy したらすぐに同じ名前で作り直せるようにする
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "valkey_app_password" {
  secret_id     = aws_secretsmanager_secret.valkey_app_password.id
  secret_string = random_password.valkey_app.result
}
