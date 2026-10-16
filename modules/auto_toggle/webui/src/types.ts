export interface OutputLine {
  content: string;
  error: boolean;
}

export type OutputCallback = (content: string, error?: boolean) => void;
