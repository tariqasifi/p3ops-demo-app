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

    stage('Build .NET') {
      steps {
        sh 'dotnet build'
      }
    }

    stage('Test') {
      steps {
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
