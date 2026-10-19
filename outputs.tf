output "aws_region" {
  value = var.aws_region
}

output "instance_id" {
  value = aws_instance.web.id
}

output "public_ip" {
  value = aws_instance.web.public_ip
}

output "web_url" {
  description = "O endereço existe mesmo com HTTP bloqueado. Aguarde o bootstrap após liberar a porta."
  value       = "http://${aws_instance.web.public_ip}"
}

output "security_group_id" {
  value = aws_security_group.web.id
}

output "vpc_id" {
  value = local.vpc_id
}

output "subnet_id" {
  value = local.subnet_id
}

output "root_volume_id" {
  value = aws_instance.web.root_block_device[0].volume_id
}
