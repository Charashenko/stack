#!/bin/bash

minikube stop
minikube delete
minikube start --cpus=12 --memory=16384
minikube addons enable ingress
kubectl create namespace apps
kubectl create namespace media
kubectl create namespace os
kubectl create namespace security
kubectl create namespace management
minikube ssh sudo mkdir -p /mnt/data/{downloads,tv,movies}
minikube ssh sudo mkdir /mnt/{apps,media,os,security,management}
sleep 2
kubectl apply -Rf .
minikube dashboard &