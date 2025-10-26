FROM google/cloud-sdk:slim

# Install necessary tools, including kubectl
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    make \
    kubectl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the monitor script from its location relative to the project root
COPY stream-monitor/monitor.sh .
RUN chmod +x monitor.sh

# Copy the recorder assets from their location relative to the project root
COPY recorder/Makefile recorder/deployment.yaml.template ./recorder/
# Copy the annotator assets from their location relative to the project root
COPY annotator/Makefile annotator/annotator-deployment.yaml.template ./annotator/

CMD ["./monitor.sh"]
