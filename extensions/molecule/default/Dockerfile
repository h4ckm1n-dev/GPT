# Use the latest Red Hat UBI (Universal Base Image)
FROM registry.access.redhat.com/ubi8/ubi:latest

# Update and install OpenSSH server and Python3
RUN yum -y update && \
    yum -y install openssh-server python3 && \
    yum clean all && \
    mkdir /var/run/sshd

# Create /opt/support directory
RUN mkdir -p /opt/support

# Add user supportbpk
RUN useradd supportbpk && \
    echo 'supportbpk:supportbpk' | chpasswd && \
    chown supportbpk:supportbpk /opt/support

# Allow root login with password
RUN echo 'root:root' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# SSH login fix. Otherwise user is kicked off after login
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

# Expose SSH port
EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
