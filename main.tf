# First, we need a place where the docker image can be pulled from by the ECS service, 
# where I used ECR. The setup of an ECR repo with Terraform is quite simple with no
# dependencies on other resources. It looks like this:


resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name
 
  policy = jsonencode({
   rules = [{
     rulePriority = 1
     description  = "keep last 10 images"
     action       = {
       type = "expire"
     }
     selection     = {
       tagStatus   = "any"
       countType   = "imageCountMoreThan"
       countNumber = 10
     }
   }]
  })
}



## Now we need a ECS cluster, which is that simple to create as below

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.cluster_name}-ecs-cluster"

  tags {
    Name = "${var.cluster_name}"
  }
}


## Next off is to have a task which 


resource "aws_ecs_task_definition" "task_definition" {
  family                   = "${var.cluster_name}-ecs-task-definition"
  task_role_arn            = "${aws_iam_role.task_role.arn}"
  execution_role_arn       = "${aws_iam_role.task_execution_role.arn}"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  container_definitions = jsonencode([{
   name        = "${var.name}-container-${var.environment}"
   image       = "${var.container_image}:latest"
   essential   = true
   environment = var.container_environment
   portMappings = [{
     protocol      = "tcp"
     containerPort = var.container_port
     hostPort      = var.container_port
   }]

  tags {
    Name = "${var.cluster_name}"
  }
}


### In order to run a task, we have to give our task a task role.

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.name}-ecsTaskRole"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
 
#This role regulates what AWS services the task has access to, 
#e.g. since ABC1s application is using a DynamoDB, task role must be given the task access to Dynamo.


resource "aws_iam_policy" "dynamodb" {
  name        = "${var.name}-task-policy-dynamodb"
  description = "Policy that allows access to DynamoDB"
 
 policy = <<EOF
{
   "Version": "2012-10-17",
   "Statement": [
       {
           "Effect": "Allow",
           "Action": [
               "dynamodb:CreateTable",
               "dynamodb:UpdateTimeToLive",
               "dynamodb:PutItem",
               "dynamodb:DescribeTable",
               "dynamodb:ListTables",
               "dynamodb:DeleteItem",
               "dynamodb:GetItem",
               "dynamodb:Scan",
               "dynamodb:Query",
               "dynamodb:UpdateItem",
               "dynamodb:UpdateTable"
           ],
           "Resource": "*"
       }
   ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "ecs-task-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.dynamodb.arn
}


##Now we need another role which allows the ECS service to pull the images from ECR,
# and spin up a contianer. 

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.name}-ecsTaskExecutionRole"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


#A service in the ECS world is basically a configuration 
#that says how many of my tasks should run in parallel,
#Here the service configuration: (this can be changed depending on our requirement)

resource "aws_ecs_service" "main" {
 name                               = "${var.name}-service-${var.environment}"
 cluster                            = aws_ecs_cluster.main.id
 task_definition                    = aws_ecs_task_definition.main.arn
 desired_count                      = 2
 deployment_minimum_healthy_percent = 50
 deployment_maximum_percent         = 200
 launch_type                        = "FARGATE"
 scheduling_strategy                = "REPLICA"
 
 network_configuration {
   security_groups  = var.ecs_service_security_groups
   subnets          = var.subnets.*.id
   assign_public_ip = false
 }
 
 load_balancer {
   target_group_arn = var.aws_alb_target_group_arn
   container_name   = "${var.name}-container-${var.environment}"
   container_port   = var.container_port
 }
 
 lifecycle {
   ignore_changes = [task_definition, desired_count]
 }
}
