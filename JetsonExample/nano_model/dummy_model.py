import torch
import torch.nn as nn
class DummyModel(nn.Module):
    def __init__(self):
        super(DummyModel, self).__init__()
        self.flatten = nn.Flatten()
        self.fc = nn.Linear(224*224*3, 10)  # Example for 10 classes

    def forward(self, x) -> torch.Tensor:
        x = self.flatten(x)
        x = self.fc(x)
        return x