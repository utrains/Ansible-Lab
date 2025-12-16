# Master Node (Ubuntu)
resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id # Changed from amazon_linux
  instance_type          = var.master-instance_type
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = aws_key_pair.ansible_key.key_name
  vpc_security_group_ids = [aws_security_group.ansible_sg.id]
  tags = {
    Name = "ansible-master-ubuntu" # Updated tag
  }
  connection {
    type        = "ssh"
    user        = "ubuntu" # Ubuntu's default user
    private_key = tls_private_key.ansible_key.private_key_pem
    host        = self.public_ip
    timeout     = "5m"
  }
  provisioner "file" {
    source      = local_file.ssh_key.filename
    destination = "ansible-key.pem" # Adjust path as needed
  }

  # Ubuntu-specific provisioning
  provisioner "remote-exec" {
    inline = [
      "sudo apt update -y",
      "sudo apt install -y python3 python3-pip git",
      "sudo pip3 install ansible",
      "sudo snap install --classic code", # Optional: Install VS Code directly
      "chmod 400 ${var.keypair_name}.pem",
      "sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^KbdInteractiveAuthentication no/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config",
      "sudo systemctl restart sshd",
      "sudo echo 'ubuntu:ansible' | sudo chpasswd", # Set password for ubuntu user
      " sudo apt update -y",
      "sudo apt install -y git sshpass python3-pip",

      # Install Ansible via pip (Ubuntu's apt version may be outdated)
      " sudo pip3 install ansible",

      # Install Amazon AWS Ansible collection
      "ansible-galaxy collection install amazon.aws",

      # Install boto3, botocore, and other Python dependencies
      " sudo pip3 install boto3 botocore awscli yamllint",
      # Create ansible user with secure practices
      #"sudo useradd -m ansible -s /bin/bash",
      #"sudo usermod -aG sudo ansible",

      # Set up authorized_keys instead of copying .pem
      # "sudo mkdir -p /home/ansible/.ssh",
      # "sudo cp .ssh/authorized_keys /home/ansible/.ssh/",
      # "sudo chown -R ansible:ansible /home/ansible/.ssh",
      # "sudo chmod 700 /home/ansible/.ssh",
      # "sudo chmod 600 /home/ansible/.ssh/authorized_keys",

      # Customize prompt
      "echo \"PS1='\\[\\e[1;32m\\]\\u@\\h \\w\\$ \\[\\e[m\\]'\" | sudo tee -a /home/ubuntu/.bashrc",

    ]
  }
}

# Node 1 (amazon-linux 2)
resource "aws_instance" "node1" {
  ami                    = data.aws_ami.amazon_linux2.id
  instance_type          = var.node-instance_type
  key_name               = aws_key_pair.ansible_key.key_name
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.ansible_sg.id]

  tags = {
    Name = "ansible-node-amazon"
  }


}

# Node 2 (ubuntu)
resource "aws_instance" "node2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.node-instance_type
  key_name               = aws_key_pair.ansible_key.key_name
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.ansible_sg.id]

  tags = {
    Name = "ansible-ubuntu"
  }
  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.ansible_key.private_key_pem
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = ["sudo apt update -y", "sudo apt install -y python3"]
  }

}

resource "local_file" "ansible_inventory" {
  filename = "ansible-dev/dev-inv.ini"
  content = var.create_windows_server ? templatefile("${path.module}/templates/inv_with_windows.tpl", {
    wind_pass = rsadecrypt(aws_instance.windows_2022[0].password_data, tls_private_key.ansible_key.private_key_pem)
    Key       = local_file.ssh_key.filename
    db_ip     = aws_instance.node2.private_ip
    ws_ip     = aws_instance.node1.private_ip
    wind_ip   = var.create_windows_server ? aws_instance.windows_2022[0].private_ip : ""
    }) : templatefile("${path.module}/templates/inv_without_windows.tpl", {
    Key   = local_file.ssh_key.filename
    db_ip = aws_instance.node2.private_ip
    ws_ip = aws_instance.node1.private_ip
  })
  depends_on = [aws_instance.master, aws_instance.node1, aws_instance.node2, aws_instance.windows_2022, local_file.ssh_key]
}

resource "null_resource" "copy_inventory" {

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.ansible_key.private_key_pem
    host        = aws_instance.master.public_ip
  }
  provisioner "file" {
    source      = "${path.module}/ansible-dev"
    destination = "/home/ubuntu/ansible-dev"
  }

  depends_on = [aws_instance.master, aws_instance.node1, aws_instance.node2, local_file.ansible_inventory]
}

resource "aws_instance" "windows_2022" {
  count         = var.create_windows_server ? 1 : 0
  ami           = data.aws_ami.windows_2022.id
  instance_type = var.windows_server_config.instance_type
  //subnet_id     = aws_subnet.your_existing_subnet.id
  key_name               = aws_key_pair.ansible_key.key_name
  get_password_data      = true
  vpc_security_group_ids = [aws_security_group.ansible_sg.id]
  subnet_id              = aws_subnet.public_subnet.id
  user_data              = filebase64("${path.module}/windows.ps1")

  tags = {
    Name = var.windows_server_config.name
    OS   = "Windows Server 2022"
    Env  = "prod"
  }
  depends_on = [aws_security_group.ansible_sg, aws_vpc.lab_vpc, aws_subnet.public_subnet]
}