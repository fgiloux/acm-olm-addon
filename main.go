package main

import (
	"flag"
	"os"

	restclient "k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"

	"open-cluster-management.io/olm-addon/pkg/manager"
)

func main() {
	klog.InitFlags(flag.CommandLine)
	flag.Parse()

	var kubeconfig *restclient.Config
	var err error
	if envKube := os.Getenv("KUBECONFIG"); envKube != "" {
		kubeconfigFile, err := os.ReadFile(envKube)
		if err != nil {
			klog.ErrorS(err, "Unable to read the kubeconfig file")
			os.Exit(1)
		}
		kubeconfig, err = clientcmd.RESTConfigFromKubeConfig(kubeconfigFile)
		if err != nil {
			klog.ErrorS(err, "Unable to create the restconfig")
			os.Exit(1)
		}
	} else {
		kubeconfig, err = restclient.InClusterConfig()
		if err != nil {
			klog.ErrorS(err, "Unable to get in cluster kubeconfig")
			os.Exit(1)
		}
	}
	manager.Start(kubeconfig)
}
