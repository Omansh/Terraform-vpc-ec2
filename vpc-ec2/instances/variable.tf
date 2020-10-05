variable "region" {
  default = 'ap-south-1'
  description = "AWS Region"
}

variable "ec2_instance_type" {
  description = "EC2 Instance Type to launch"
}

variable "key_pair_name" {
  default = "tgr-key"
  description = "Keypair to use to connect to EC2 Instances"
}

variable "max_instance_size" {
  description = "Maximum number of instances to Launch"
}

variable "min_instance_size" {
  description = "Minimum number of instances to launch"
}