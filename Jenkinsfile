pipeline {
  agent any

  triggers {
    githubPush()
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Test dotnet') {
      steps {
        sh 'dotnet --version'
        sh 'dotnet test'
      }
    }

    stage('Docker Build') {
      steps {
        dir('src') {
          sh 'docker build -t ghcr.io/tariqasifi/sportstore:latest .'
        }
      }
    }
  }
}
