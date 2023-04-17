resource "aws_key_pair" "wbat" {
  key_name   = "WBAT"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAbfdIFRhw+NFOytsJgWNRuCwpDSIrYm1g0UOpMQ1N8/yNiYKnREARbah2p8RMqnf0Hu054DEwfdtR836STs2txbFnZmfZgiVfAfjZQSqCuxMNmccJD3kQSOVHXU5L/2t+XIw8IDDzB+4EuWoOuO1BlYTu+GdTPgVDcHyhlqE2BfD329DoJ2CTui1EE14OupmPDztW8Rl1Hwz7ud4TJ0hhWZb07fFP35yvjDdKaknwcPzsa/IH2V4eZ7gDDQUl+TppTB9Ohx8tfMWwjFBNR86C2UqJxUCz3VAA/YRoPY7BCxsJ1Iu+GhNmM9pPlmIkFXbI+DRS6sgrJ9W3ouRkTpzL"

  tags = merge(
    var.core_tags,
    {
      Name       = "WBAT",
      "scm:file" = "aws/us-east-1/ec2/key-pair.tf",
    },
  )
}
