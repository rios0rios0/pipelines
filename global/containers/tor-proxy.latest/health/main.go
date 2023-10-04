package main

import (
	logger "github.com/sirupsen/logrus"
	"io/ioutil"
	"net"
	"net/http"
	"net/url"
)

func doRequest(site string) string {
	response := ""
	proxyUrl, errProxy := url.Parse("socks5://localhost:9050")
	if errProxy != nil {
		logger.Errorf("Proxy is not ready yet... %s", errProxy)
	} else {
		httpClient := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyUrl)}}
		result, errHttpClient := httpClient.Get(site)
		if errHttpClient != nil {
			logger.Errorf("HTTP Client creation returned an error... %s", errHttpClient)
		} else {
			body, errReading := ioutil.ReadAll(result.Body)
			if errReading != nil {
				logger.Errorf("It wasn't able to parse the body response... %s", errReading)
			} else {
				response = string(body)
			}
		}
	}
	return response
}

func main() {
	http.HandleFunc("/health", func(response http.ResponseWriter, request *http.Request) {
		body := doRequest("https://ifconfig.me")
		if body != "" && net.ParseIP(body) != nil {
			logger.Infof("Health check verified, everything is fine! Here is my IP: %s", body)
			response.WriteHeader(http.StatusOK)
		} else {
			logger.Errorf("Health check error! The proxy is not working... Output: %s", body)
			response.WriteHeader(http.StatusBadRequest)
		}
	})
	errServer := http.ListenAndServe(":8080", nil)
	if errServer != nil {
		panic(errServer)
	}
}
