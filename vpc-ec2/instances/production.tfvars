#Give the instance size as per the requirement, for here we have used t2.micro as it's free tire.
ec2_instance_type = "t2.micro"

#Specify the maximum number of instances that you want to launch in the autoscaling groups.
max_instance_size = "4"

#Specify the minimum number of instances that you want to launch in the autoscaling groups.
min_instance_size = "2"